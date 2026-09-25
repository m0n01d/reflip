// Email.buildMime is pure, so it's hand-checked against a fixed boundary
// with no network. decodeAccessToken and credsFromEnv need no I/O either.

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

let run = () => {
  TestKit.section("Email.buildMime")

  let subject = "Café — 3 gems ✓" // "Café — 3 gems ✓"
  let html = "<p>Café — 3 gems ✓</p>"
  let text = "Cafe summary"
  let msg: Email.message = {
    to_: "dwight@example.com",
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

  // -- Subject: decode the RFC 2047 encoded word back and compare exactly.
  let subjectLine =
    Array.filterMap(lines, l => String.startsWith(l, "Subject: ") ? Some(l) : None)->Array.get(0)
  switch subjectLine {
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

  TestKit.section("Email.decodeAccessToken")

  TestKit.check(
    "Some for a genuine token reply",
    Email.decodeAccessToken(JSON.parseOrThrow(`{"access_token":"x","expires_in":3600}`)) == Some("x"),
  )
  TestKit.check(
    "None for an error reply with no access_token",
    Email.decodeAccessToken(JSON.parseOrThrow(`{"error":"invalid_grant"}`)) == None,
  )
  TestKit.check(
    "None for a JSON value that isn't an object",
    Email.decodeAccessToken(JSON.parseOrThrow(`"just a string"`)) == None,
  )

  TestKit.section("Email.credsFromEnv")

  let noEnv = (_: string): option<string> => None
  switch Email.credsFromEnv(noEnv) {
  | Error(missing) => TestKit.check("all four names are reported missing", Array.length(missing) == 4)
  | Ok(_) => TestKit.check("credsFromEnv should fail with no environment", false)
  }

  let partialEnv = (k: string): option<string> =>
    switch k {
    | "GMAIL_CLIENT_ID" => Some("id")
    | "EMAIL_TO" => Some("me@example.com")
    | _ => None
    }
  switch Email.credsFromEnv(partialEnv) {
  | Error(missing) =>
    TestKit.check(
      "only the actually-missing names are listed, in order",
      Array.length(missing) == 2 &&
        Array.getUnsafe(missing, 0) == "GMAIL_CLIENT_SECRET" &&
        Array.getUnsafe(missing, 1) == "GMAIL_REFRESH_TOKEN",
    )
  | Ok(_) => TestKit.check("credsFromEnv should fail with a partial environment", false)
  }

  let fullEnv = (k: string): option<string> =>
    switch k {
    | "GMAIL_CLIENT_ID" => Some("id")
    | "GMAIL_CLIENT_SECRET" => Some("secret")
    | "GMAIL_REFRESH_TOKEN" => Some("refresh")
    | "EMAIL_TO" => Some("me@example.com")
    | _ => None
    }
  TestKit.check("a complete environment decodes to Ok", switch Email.credsFromEnv(fullEnv) {
  | Ok(_) => true
  | Error(_) => false
  })
}
