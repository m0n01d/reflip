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
      TestKit.check("scene fixture has no otherCount", decoded.otherCount == None)
      TestKit.check("scene fixture reports quarterSeen true", decoded.quarterSeen == true)
      TestKit.check(
        "scene fixture's skillet has a size",
        Array.get(decoded.items, 1)->Option.map(i => i.size) == Some("10 in"),
      )
      TestKit.check(
        "scene fixture's board game lot has no size key, decoded as an empty string",
        Array.get(decoded.items, 2)->Option.map(i => i.size) == Some(""),
      )
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

  // Haul mode (step 4): the fixture's items each carry `where`, and the
  // reply names its otherCount.
  let haulFixturePath = Node.Path.join([Node.Process.cwd(), "tests/fixtures/claude-haul.json"])
  let haulFixtureJson = JSON.parseOrThrow(Node.Fs.readFileUtf8(haulFixturePath, "utf8"))
  switch ClaudeClient.decodeResponse(haulFixtureJson) {
  | Ok(decoded) => {
      TestKit.check("haul fixture has 3 items", Array.length(decoded.items) == 3)
      TestKit.check(
        "haul fixture's first item has a where",
        Array.get(decoded.items, 0)->Option.flatMap(i => i.where)->Option.isSome,
      )
      TestKit.check("haul fixture otherCount is 12", decoded.otherCount == Some(12))
      TestKit.check(
        "haul fixture's skillet has a size",
        Array.get(decoded.items, 1)->Option.map(i => i.size) == Some("No. 8"),
      )
      TestKit.check(
        "haul fixture's brooch has no size key, decoded as an empty string",
        Array.get(decoded.items, 2)->Option.map(i => i.size) == Some(""),
      )
      // The haul prompt asks for no box, so a haul item decodes with None.
      TestKit.check(
        "haul fixture items have no box",
        Array.every(decoded.items, i => i.box == None),
      )
    }
  | Error(_) => TestKit.check("haul fixture decodes", false)
  }

  // A reply with no size on its item and no top-level quarterSeen at all —
  // both should decode to their defaults, not fail the decode.
  let noScaleRefFields = Json.obj([
    (
      "content",
      Json.arr([
        Json.obj([
          (
            "type",
            Json.str("text"),
          ),
          (
            "text",
            Json.str(
              "{\"items\": [{\"name\": \"Mystery item\", \"maker\": \"\", \"query\": \"mystery item\", \"estimateLowUsd\": 1, \"estimateHighUsd\": 2, \"basis\": \"guess\", \"confidence\": 0.1, \"sources\": []}]}",
            ),
          ),
        ]),
      ]),
    ),
    ("usage", Json.obj([("input_tokens", Json.num(1.0)), ("output_tokens", Json.num(1.0))])),
  ])
  switch ClaudeClient.decodeResponse(noScaleRefFields) {
  | Ok(decoded) => {
      TestKit.check(
        "a missing size on an item decodes as an empty string",
        Array.get(decoded.items, 0)->Option.map(i => i.size) == Some(""),
      )
      TestKit.check("a missing top-level quarterSeen decodes as false", decoded.quarterSeen == false)
    }
  | Error(_) => TestKit.check("a reply with no scale-ref fields still decodes", false)
  }

  // A reply cut short by the token limit is a different callError, not a
  // decode failure: parseClaudeJson checks stop_reason before it ever
  // calls decodeResponse.
  let maxTokensJson = Json.obj([
    ("stop_reason", Json.str("max_tokens")),
    (
      "content",
      Json.arr([
        Json.obj([("type", Json.str("text")), ("text", Json.str("{\"items\": ["))]),
      ]),
    ),
    ("usage", Json.obj([("input_tokens", Json.num(1.0)), ("output_tokens", Json.num(1.0))])),
  ])
  switch ClaudeClient.parseClaudeJson(maxTokensJson) {
  | Error(ClaudeClient.CutOff) => TestKit.check("stop_reason max_tokens gives CutOff", true)
  | _ => TestKit.check("stop_reason max_tokens should give CutOff", false)
  }

  switch ClaudeClient.parseClaudeJson(fixtureJson) {
  | Ok(decoded) =>
    TestKit.check("parseClaudeJson still decodes a normal reply", Array.length(decoded.items) == 3)
  | Error(_) => TestKit.check("parseClaudeJson should decode a normal reply", false)
  }
}
