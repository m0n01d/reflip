// Email.buildMime is pure, so it's hand-checked against a fixed boundary
// with no network. credsFromEnv needs no I/O either. Email.send is
// exercised through nodemailer's StreamTransport (Nodemailer.res), which
// buffers the raw message instead of opening a socket — still no network.

// -- small MIME-parsing helpers, test-local only ---------------------------

let crlfLines = (s: string): array<string> => String.split(s, "\r\n")

// True only if every "\n" is preceded by "\r" and every "\r" is followed by
// "\n" — i.e. the whole string uses strict CRLF line endings, no bare LF.
let strictCrlf = (s: string): bool => {
  let len = String.length(s)
  let rec go = i =>
    if i >= len {
      true
    } else {
      switch String.charAt(s, i) {
      | "\n" => i > 0 && String.charAt(s, i - 1) == "\r" ? go(i + 1) : false
      | "\r" => i + 1 < len && String.charAt(s, i + 1) == "\n" ? go(i + 1) : false
      | _ => go(i + 1)
      }
    }
  go(0)
}

// The base64 body of the part whose header line is `headerLine`: every
// line after the first blank line that follows it, up to (excluding) the
// next "--boundary" line, concatenated back into one base64 string.
let partBody = (lines: array<string>, ~headerLine: string): string => {
  let n = Array.length(lines)
  let rec findHeader = i =>
    if i >= n {
      -1
    } else if Array.getUnsafe(lines, i) == headerLine {
      i
    } else {
      findHeader(i + 1)
    }
  let headerIdx = findHeader(0)
  let rec findBlank = i => Array.getUnsafe(lines, i) == "" ? i : findBlank(i + 1)
  let blankIdx = findBlank(headerIdx + 1)
  let rec collect = (i, acc) =>
    if String.startsWith(Array.getUnsafe(lines, i), "--") {
      acc
    } else {
      collect(i + 1, acc ++ Array.getUnsafe(lines, i))
    }
  collect(blankIdx + 1, "")
}

let decodeBase64Utf8 = (b64: string): string =>
  Node.Buffer.toStringWithEncoding(Node.Buffer.fromString(b64, "base64"), "utf8")

// The single line starting with `prefix`, if there's exactly one.
let lineStarting = (lines: array<string>, ~prefix: string): option<string> =>
  Array.filterMap(lines, l => String.startsWith(l, prefix) ? Some(l) : None)->Array.get(0)

let run = async () => {
  TestKit.section("Email.buildMime")

  let subject = "Café — 3 gems ✓" // "Café — 3 gems ✓"
  let html = "<p>Café — 3 gems ✓</p>"
  let text = "Cafe summary"
  let from_ = "reflip@example.com"
  let to_ = "dwight@example.com"
  let date = "Fri, 25 Sep 2026 12:00:00 GMT"
  let msg: Email.message = {
    to_,
    from_,
    date,
    subject,
    text,
    html,
    images: [
      {
        Email.cid: "gem-scene-a@reflip",
        filename: "scene-a.jpg",
        jpeg: Node.Buffer.fromString("not a real jpeg, just bytes", "utf8"),
      },
    ],
  }
  let boundary = "TESTBOUNDARY123"
  let mime = Email.buildMime(msg, ~boundary)
  let lines = crlfLines(mime)

  // -- From and Date: SMTP sends these raw bytes as-is (the Gmail API used
  // to fill From for us), so buildMime now writes both headers verbatim.
  TestKit.check(
    "the From header carries the sender address",
    lineStarting(lines, ~prefix="From: ") == Some("From: " ++ from_),
  )
  TestKit.check(
    "the Date header carries the caller's RFC 5322 date",
    lineStarting(lines, ~prefix="Date: ") == Some("Date: " ++ date),
  )
  TestKit.check(
    "the To header carries the recipient address",
    lineStarting(lines, ~prefix="To: ") == Some("To: " ++ to_),
  )

  // -- Subject: decode the RFC 2047 encoded word back and compare exactly.
  switch lineStarting(lines, ~prefix="Subject: ") {
  | None => TestKit.check("a Subject header line exists", false)
  | Some(line) => {
      let encoded = String.substring(line, ~start=String.length("Subject: "), ~end=String.length(line))
      TestKit.check("the Subject is an RFC 2047 UTF-8 base64 encoded word", String.startsWith(encoded, "=?UTF-8?B?"))
      let inner = String.substring(
        encoded,
        ~start=String.length("=?UTF-8?B?"),
        ~end=String.length(encoded) - String.length("?="),
      )
      TestKit.check("the decoded Subject matches the original exactly", decodeBase64Utf8(inner) == subject)
    }
  }

  // -- html part: decode its base64 body back and compare exactly.
  let htmlBody = partBody(lines, ~headerLine="Content-Type: text/html; charset=UTF-8")
  TestKit.check("the decoded html part matches the original exactly", decodeBase64Utf8(htmlBody) == html)

  // -- text part, same check.
  let textBody = partBody(lines, ~headerLine="Content-Type: text/plain; charset=UTF-8")
  TestKit.check("the decoded text part matches the original exactly", decodeBase64Utf8(textBody) == text)

  // -- line discipline: strict CRLF, and no line over 998 chars (RFC 5322).
  TestKit.check("every line ends CRLF, no bare LF or CR", strictCrlf(mime))
  TestKit.check(
    "no line is longer than 998 chars",
    Array.reduceWithIndex(lines, true, (ok, line, _i) => ok && String.length(line) <= 998),
  )

  // -- the inline image part carries its Content-ID.
  TestKit.check(
    "the image part has its Content-ID",
    String.includes(mime, "Content-ID: <gem-scene-a@reflip>"),
  )
  TestKit.check(
    "the image part is inline with its filename",
    String.includes(mime, "Content-Disposition: inline; filename=\"scene-a.jpg\""),
  )

  TestKit.section("Email.credsFromEnv")

  let noEnv = (_: string): option<string> => None
  switch Email.credsFromEnv(noEnv) {
  | Error(missing) =>
    TestKit.check(
      "both names are reported missing, in order",
      Array.length(missing) == 2 &&
        Array.getUnsafe(missing, 0) == "GMAIL_USER" &&
        Array.getUnsafe(missing, 1) == "GMAIL_APP_PASSWORD",
    )
  | Ok(_) => TestKit.check("credsFromEnv should fail with no environment", false)
  }

  let onlyUser = (k: string): option<string> =>
    switch k {
    | "GMAIL_USER" => Some("dwight@gmail.com")
    | _ => None
    }
  switch Email.credsFromEnv(onlyUser) {
  | Error(missing) =>
    TestKit.check(
      "only GMAIL_APP_PASSWORD is reported missing",
      Array.length(missing) == 1 && Array.getUnsafe(missing, 0) == "GMAIL_APP_PASSWORD",
    )
  | Ok(_) => TestKit.check("credsFromEnv should fail with only GMAIL_USER set", false)
  }

  let noEmailTo = (k: string): option<string> =>
    switch k {
    | "GMAIL_USER" => Some("dwight@gmail.com")
    | "GMAIL_APP_PASSWORD" => Some("app-password")
    | _ => None
    }
  TestKit.check(
    "EMAIL_TO defaults to GMAIL_USER when unset",
    switch Email.credsFromEnv(noEmailTo) {
    | Ok(creds) => creds.emailTo == "dwight@gmail.com"
    | Error(_) => false
    },
  )

  let withEmailTo = (k: string): option<string> =>
    switch k {
    | "GMAIL_USER" => Some("dwight@gmail.com")
    | "GMAIL_APP_PASSWORD" => Some("app-password")
    | "EMAIL_TO" => Some("haul-digest@example.com")
    | _ => None
    }
  TestKit.check(
    "EMAIL_TO is used when set",
    switch Email.credsFromEnv(withEmailTo) {
    | Ok(creds) => creds.emailTo == "haul-digest@example.com"
    | Error(_) => false
    },
  )

  TestKit.section("Email.send through nodemailer's stream transport")

  let creds: Email.creds = {user: from_, appPassword: "app-password", emailTo: to_}
  let sendMime = Email.buildMime(msg, ~boundary="SENDTEST")
  let transport = Nodemailer.createStreamTransport({streamTransport: true, buffer: true})

  TestKit.check(
    "Email.send resolves Ok through the stream transport",
    switch await Email.send(~transport, ~creds, ~mime=sendMime) {
    | Ok() => true
    | Error(_) => false
    },
  )

  // A second call against the same stream transport, this time reading the
  // raw nodemailer reply directly (Nodemailer.sendMailStream), to check the
  // envelope and the buffered message Email.send can't see through its own
  // result<unit, string>.
  let info = await Nodemailer.sendMailStream(
    transport,
    {Nodemailer.envelope: {from: creds.user, to: [creds.emailTo]}, raw: sendMime},
  )
  TestKit.check("the reply envelope's from is the sender", info.envelope.from == creds.user)
  TestKit.check("the reply envelope's to is the recipient", info.envelope.to == [creds.emailTo])
  TestKit.check(
    "the buffered message equals the mime string",
    Node.Buffer.toStringWithEncoding(info.message, "utf8") == sendMime,
  )
}
