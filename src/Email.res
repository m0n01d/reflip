// Node port of dippa's Gmail-API sender (src/worker/Email.res, dippa commit
// 914f551), with two fixes that docs/spec-haul-mode.md and flip-scout.md
// (app-ideas) name:
//
//   (a) UTF-8. dippa strips every non-ASCII character to "?" (`toAscii`,
//       via `btoa`, which can only encode Latin-1 code points) before
//       sending. This module instead base64-encodes each part's real UTF-8
//       bytes through Node's Buffer, and RFC-2047-encodes the Subject
//       header the same way, so a store name like "Café" or an emoji in a
//       gem's name survives.
//   (b) The token response decodes through Json.res's option-returning
//       helpers, never dippa's `asTokenResp: Js.Json.t => tokenResp =
//       "%identity"` cast (CLAUDE.md bans %identity).
//
// dippa sends a single text/html email with no attachments. Haul mode's
// digest needs inline gem thumbnails, so this module builds a
// multipart/related MIME message (a multipart/alternative text+html part,
// plus one image/jpeg part per inline image) instead of dippa's bare
// text/html body. The Gmail endpoints and the token-refresh request shape
// are otherwise unchanged from dippa.

type inlineImage = {cid: string, filename: string, jpeg: Node.Buffer.t}

type message = {
  to_: string,
  subject: string,
  text: string,
  html: string,
  images: array<inlineImage>,
}

type creds = {clientId: string, clientSecret: string, refreshToken: string, emailTo: string}

let crlf = "\r\n"

// -- base64 helpers -----------------------------------------------------

// `parts` at 76 chars each, CRLF-joined — the MIME line-length convention
// dippa didn't need (it sent one unencoded HTML part, never base64 body
// content).
let wrapBase64 = (b64: string): string => {
  let len = String.length(b64)
  let rec go = (i, acc) =>
    if i >= len {
      acc
    } else {
      let chunkLen = len - i < 76 ? len - i : 76
      let chunk = String.substring(b64, ~start=i, ~end=i + chunkLen)
      let acc2 = acc == "" ? chunk : acc ++ crlf ++ chunk
      go(i + chunkLen, acc2)
    }
  go(0, "")
}

// The real UTF-8 bytes of `s`, base64-encoded and line-wrapped — the fix
// for dippa's `toAscii`.
let base64Utf8Wrapped = (s: string): string =>
  wrapBase64(Node.Buffer.toStringWithEncoding(Node.Buffer.fromString(s, "utf8"), "base64"))

// RFC 2047 encoded word for a header value that may hold non-ASCII, e.g.
// the Subject line.
let encodedWord = (s: string): string =>
  "=?UTF-8?B?" ++
  Node.Buffer.toStringWithEncoding(Node.Buffer.fromString(s, "utf8"), "base64") ++
  "?="

// web-safe, unpadded base64 for the Gmail API's `raw` field (RFC 4648 §5).
let base64Url = (s: string): string => {
  let b64 = Node.Buffer.toStringWithEncoding(Node.Buffer.fromString(s, "utf8"), "base64")
  let len = String.length(b64)
  let rec go = (i, acc) =>
    if i >= len {
      acc
    } else {
      let piece = switch String.charAt(b64, i) {
      | "+" => "-"
      | "/" => "_"
      | "=" => ""
      | other => other
      }
      go(i + 1, acc ++ piece)
    }
  go(0, "")
}

// -- MIME ----------------------------------------------------------------

// Pure: no I/O, no randomness. `boundary` is caller-supplied so the output
// is deterministic and testable.
let buildMime = (msg: message, ~boundary: string): string => {
  let altBoundary = boundary ++ "-alt"
  let textPart =
    "--" ++
    altBoundary ++
    crlf ++
    "Content-Type: text/plain; charset=UTF-8" ++
    crlf ++
    "Content-Transfer-Encoding: base64" ++
    crlf ++
    crlf ++
    base64Utf8Wrapped(msg.text) ++
    crlf
  let htmlPart =
    "--" ++
    altBoundary ++
    crlf ++
    "Content-Type: text/html; charset=UTF-8" ++
    crlf ++
    "Content-Transfer-Encoding: base64" ++
    crlf ++
    crlf ++
    base64Utf8Wrapped(msg.html) ++
    crlf
  let alternativePart =
    "--" ++
    boundary ++
    crlf ++
    "Content-Type: multipart/alternative; boundary=\"" ++
    altBoundary ++
    "\"" ++
    crlf ++
    crlf ++
    textPart ++
    htmlPart ++
    "--" ++
    altBoundary ++
    "--" ++
    crlf
  let imageParts = Array.reduceWithIndex(msg.images, "", (acc, img, _i) =>
    acc ++
    "--" ++
    boundary ++
    crlf ++
    "Content-Type: image/jpeg; name=\"" ++
    img.filename ++
    "\"" ++
    crlf ++
    "Content-Transfer-Encoding: base64" ++
    crlf ++
    "Content-ID: <" ++
    img.cid ++
    ">" ++
    crlf ++
    "Content-Disposition: inline; filename=\"" ++
    img.filename ++
    "\"" ++
    crlf ++
    crlf ++
    wrapBase64(Node.Buffer.toStringWithEncoding(img.jpeg, "base64")) ++
    crlf
  )
  let headers =
    "To: " ++
    msg.to_ ++
    crlf ++
    "Subject: " ++
    encodedWord(msg.subject) ++
    crlf ++
    "MIME-Version: 1.0" ++
    crlf ++
    "Content-Type: multipart/related; boundary=\"" ++
    boundary ++
    "\"" ++
    crlf ++
    crlf
  headers ++ alternativePart ++ imageParts ++ "--" ++ boundary ++ "--" ++ crlf
}

// -- config ----------------------------------------------------------------

// `getEnv` is injected (rather than reading Node.Process.env directly) so
// EmailTest.res can call this with no real environment.
let credsFromEnv = (getEnv: string => option<string>): result<creds, array<string>> => {
  let names = ["GMAIL_CLIENT_ID", "GMAIL_CLIENT_SECRET", "GMAIL_REFRESH_TOKEN", "EMAIL_TO"]
  let missing = Array.filter(names, n =>
    switch getEnv(n) {
    | None => true
    | Some(_) => false
    }
  )
  if Array.length(missing) > 0 {
    Error(missing)
  } else {
    Ok({
      clientId: getEnv("GMAIL_CLIENT_ID")->Option.getOr(""),
      clientSecret: getEnv("GMAIL_CLIENT_SECRET")->Option.getOr(""),
      refreshToken: getEnv("GMAIL_REFRESH_TOKEN")->Option.getOr(""),
      emailTo: getEnv("EMAIL_TO")->Option.getOr(""),
    })
  }
}

// -- Gmail API ---------------------------------------------------------

// The fix for dippa's `asTokenResp: Js.Json.t => tokenResp = "%identity"`:
// every field comes through Json.res's option-returning decoders. `Some`
// only for a genuine `{"access_token": "..."}` reply; `None` for an error
// body (e.g. `{"error": "invalid_grant"}`) or anything that isn't a JSON
// object.
let decodeAccessToken = (json: JSON.t): option<string> => Json.stringField(json, "access_token")

let accessToken = async (creds: creds): result<string, string> => {
  let form =
    "client_id=" ++
    encodeURIComponent(creds.clientId) ++
    "&client_secret=" ++
    encodeURIComponent(creds.clientSecret) ++
    "&refresh_token=" ++
    encodeURIComponent(creds.refreshToken) ++
    "&grant_type=refresh_token"
  let resp = await Fetch.fetch(
    "https://oauth2.googleapis.com/token",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "application/x-www-form-urlencoded")]),
      body: form,
    },
  )
  if Fetch.ok(resp) {
    switch decodeAccessToken(await Fetch.json(resp)) {
    | Some(token) => Ok(token)
    | None => Error("gmail token refresh reply had no access_token")
    }
  } else {
    Error("gmail token refresh failed with status " ++ Int.toString(Fetch.status(resp)))
  }
}

let send = async (~creds: creds, ~mime: string): result<unit, string> =>
  switch await accessToken(creds) {
  | Error(e) => Error(e)
  | Ok(token) => {
      let body = Json.obj([("raw", Json.str(base64Url(mime)))])
      let resp = await Fetch.fetch(
        "https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
        ~init={
          Fetch.method: "POST",
          headers: Dict.fromArray([
            ("content-type", "application/json"),
            ("authorization", "Bearer " ++ token),
          ]),
          body: JSON.stringify(body),
        },
      )
      if Fetch.ok(resp) {
        Ok()
      } else {
        Error(
          "gmail send failed with status " ++
          Int.toString(Fetch.status(resp)) ++
          ": " ++
          (await Fetch.text(resp)),
        )
      }
    }
  }

// -- fixture-mode fallback -----------------------------------------------

// FIXTURES=1, or a missing Gmail secret outside fixture mode (see
// docs/spec-haul-mode.md, "The digest and the email"): the brain writes
// the MIME message here instead of calling the network. Returns the path.
let writeOutbox = (~dir: string, ~haulId: string, ~mime: string): string => {
  Node.Fs.mkdirSync(dir, {recursive: true})
  let path = Node.Path.join([dir, haulId ++ ".eml"])
  Node.Fs.writeFileSync(path, mime)
  path
}
