// Claude decode: the fixture gives 3 items. Malformed text gives the error
// variant, and prose-wrapped JSON still recovers via the brace-span
// fallback.

let run = () => {
  TestKit.section("ClaudeClient.decodeResponse")

  let fixturePath = Node.Path.join([Node.Process.cwd(), "tests/fixtures/claude-scene.json"])
  let fixtureJson = JSON.parseOrThrow(Node.Fs.readFileUtf8(fixturePath, "utf8"))
  switch ClaudeClient.decodeResponse(fixtureJson) {
  | Ok(decoded) => {
      TestKit.check("fixture has 3 items", Array.length(decoded.items) == 3)
      TestKit.check("fixture usage has 2 web searches", decoded.usage.webSearchRequests == 2)
    }
  | Error(_) => TestKit.check("fixture decodes", false)
  }

  let malformed = Json.obj([
    (
      "content",
      Json.arr([
        Json.obj([("type", Json.str("text")), ("text", Json.str("not json at all"))]),
      ]),
    ),
    ("usage", Json.obj([("input_tokens", Json.num(1.0)), ("output_tokens", Json.num(1.0))])),
  ])
  switch ClaudeClient.decodeResponse(malformed) {
  | Error(_) => TestKit.check("malformed text is an error variant", true)
  | Ok(_) => TestKit.check("malformed text should not decode", false)
  }

  let recoverable = Json.obj([
    (
      "content",
      Json.arr([
        Json.obj([
          ("type", Json.str("text")),
          ("text", Json.str("Here you go: {\"items\": []} — hope that helps!")),
        ]),
      ]),
    ),
    ("usage", Json.obj([("input_tokens", Json.num(1.0)), ("output_tokens", Json.num(1.0))])),
  ])
  switch ClaudeClient.decodeResponse(recoverable) {
  | Ok(d) =>
    TestKit.check("brace-span fallback recovers an empty items array", Array.length(d.items) == 0)
  | Error(_) => TestKit.check("brace-span fallback should recover", false)
  }
}
