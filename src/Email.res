// Sends the haul digest through Gmail SMTP with an app password, via
// nodemailer (src/bindings/Nodemailer.res). Dwight chose this on 2026-09-25
// because he has a Gmail app password and no OAuth keys — this replaces an
// earlier OAuth2 / Gmail-API port of dippa's src/worker/Email.res (dippa
// commit 914f551). The MIME building below is unchanged from that port,
// with two fixes docs/spec-haul-mode.md and flip-scout.md (app-ideas) name:
//
//   (a) UTF-8. dippa strips every non-ASCII character to "?" (`toAscii`,
//       via `btoa`, which can only encode Latin-1 code points) before
//       sending. This module instead base64-encodes each part's real UTF-8
//       bytes through Node's Buffer, and RFC-2047-encodes the Subject
//       header the same way, so a store name like "Café" or an emoji in a
//       gem's name survives.
//   (b) The token response decoded through Json.res's option-returning
//       helpers, never dippa's `asTokenResp: Js.Json.t => tokenResp =
//       "%identity"` cast (CLAUDE.md bans %identity). SMTP has no token
//       response to decode, but `send` below keeps the same discipline: the
//       nodemailer reply is JSON.t, decoded at the edge, never cast.
//
// dippa sends a single text/html email with no attachments. Haul mode's
// digest needs inline gem thumbnails, so this module builds a
// multipart/related MIME message (a multipart/alternative text+html part,
// plus one image/jpeg part per inline image) instead of dippa's bare
// text/html body.

type inlineImage = {cid: string, filename: string, jpeg: Node.Buffer.t}

type message = {
  to_: string,
  from_: string,
  date: string,
  subject: string,
  text: string,
  html: string,
  images: array<inlineImage>,
}

type creds = {user: string, appPassword: string, emailTo: string}

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
  // SMTP sends these raw bytes as-is (the Gmail API filled `From` for us),
  // so `From` and `Date` are now this module's job, not the transport's.
  let headers =
    "From: " ++
    msg.from_ ++
    crlf ++
    "To: " ++
    msg.to_ ++
    crlf ++
    "Date: " ++
    msg.date ++
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
  let names = ["GMAIL_USER", "GMAIL_APP_PASSWORD"]
  let missing = Array.filter(names, n =>
    switch getEnv(n) {
    | None => true
    | Some(_) => false
    }
  )
  if Array.length(missing) > 0 {
    Error(missing)
  } else {
    let user = getEnv("GMAIL_USER")->Option.getOr("")
    Ok({
      user,
      appPassword: getEnv("GMAIL_APP_PASSWORD")->Option.getOr(""),
      emailTo: getEnv("EMAIL_TO")->Option.getOr(user),
    })
  }
}

// -- Gmail SMTP ----------------------------------------------------------

let gmailTransport = (creds: creds): Nodemailer.transporter =>
  Nodemailer.createTransport({
    host: "smtp.gmail.com",
    port: 465,
    secure: true,
    auth: {Nodemailer.user: creds.user, pass: creds.appPassword},
    connectionTimeout: 15000,
    greetingTimeout: 15000,
    socketTimeout: 30000,
  })

// No Array.join in this codebase (see HaulEmail.res's own joinComma) — same
// small fold, local to this module.
let joinComma = (parts: array<string>): string =>
  Array.reduceWithIndex(parts, "", (acc, part, i) => i == 0 ? part : acc ++ ", " ++ part)

// The nodemailer reply decodes through Json.res, never a cast (see the
// module comment's fix (b)): `rejected` is `Some(non-empty array)` only for
// a genuine per-recipient SMTP rejection; anything else (a name-only stub
// transport's reply, an empty `rejected`) means every recipient was
// accepted. A thrown JsExn — a bad login, a closed connection, a DNS
// failure — becomes an Error with its message. The app password never
// appears in that message: nodemailer's own auth errors name the failure
// ("Invalid login", a socket code), never the credential.
let send = async (~transport: Nodemailer.transporter, ~creds: creds, ~mime: string): result<
  unit,
  string,
> =>
  try {
    let info = await Nodemailer.sendMail(
      transport,
      {Nodemailer.envelope: {from: creds.user, to: [creds.emailTo]}, raw: mime},
    )
    switch Json.arrayField(info, "rejected") {
    | Some(rejected) if Array.length(rejected) > 0 =>
      Error("gmail smtp rejected " ++ joinComma(Array.filterMap(rejected, JSON.Decode.string)))
    | _ => Ok()
    }
  } catch {
  | JsExn(e) => Error(JsExn.message(e)->Option.getOr("unknown SMTP error"))
  }

// A login only — no message is sent. Used by `npm run email:check`
// (EmailCheck.res) so Dwight can confirm the app password works before haul
// mode sends a real digest through it.
let verify = async (~transport: Nodemailer.transporter): result<unit, string> =>
  try {
    let _ = await Nodemailer.verify(transport)
    Ok()
  } catch {
  | JsExn(e) => Error(JsExn.message(e)->Option.getOr("unknown SMTP error"))
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
