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
      TestKit.check(
        "scene fixture's bowl set is large with no tag",
        Array.get(decoded.items, 0)->Option.map(i => (i.shipClass, i.tagPriceUsd)) ==
          Some((Profit.Large, None)),
      )
      TestKit.check(
        "scene fixture's skillet is medium with a $12 tag",
        Array.get(decoded.items, 1)->Option.map(i => (i.shipClass, i.tagPriceUsd)) ==
          Some((Profit.Medium, Some(12.0))),
      )
      TestKit.check(
        "scene fixture's board game lot is large with a $2.50 tag",
        Array.get(decoded.items, 2)->Option.map(i => (i.shipClass, i.tagPriceUsd)) ==
          Some((Profit.Large, Some(2.5))),
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
      // The haul prompt now asks for a box too (haul-3), so every item
      // decodes a raw box array here — Box.decode's validity check (the
      // skillet's is degenerate, tests/fixtures/README.md) happens later,
      // once the sent photo's size is known, not in this raw decode.
      TestKit.check(
        "haul fixture items each carry a raw box",
        Array.every(decoded.items, i => i.box->Option.isSome),
      )
      TestKit.check(
        "haul fixture's lamp is large with no tag",
        Array.get(decoded.items, 0)->Option.map(i => (i.shipClass, i.tagPriceUsd)) ==
          Some((Profit.Large, None)),
      )
      TestKit.check(
        "haul fixture's skillet is medium with a $12 tag",
        Array.get(decoded.items, 1)->Option.map(i => (i.shipClass, i.tagPriceUsd)) ==
          Some((Profit.Medium, Some(12.0))),
      )
      TestKit.check(
        "haul fixture's brooch is small with a $2.50 tag",
        Array.get(decoded.items, 2)->Option.map(i => (i.shipClass, i.tagPriceUsd)) ==
          Some((Profit.Small, Some(2.5))),
      )
      switch Array.get(decoded.items, 2) {
      | Some(brooch) =>
        let estimate = Profit.estimate(
          ~lowUsd=brooch.estimateLowUsd,
          ~highUsd=brooch.estimateHighUsd,
          ~shipClass=brooch.shipClass,
          ~tagPriceUsd=brooch.tagPriceUsd,
        )
        TestKit.check(
          "haul fixture's brooch estimate, at its tag, is a loss",
          Profit.isLoss(estimate),
        )
      | None => TestKit.check("haul fixture's brooch is present to price", false)
      }
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
      TestKit.check(
        "a missing shipClass falls back to Medium",
        Array.get(decoded.items, 0)->Option.map(i => i.shipClass) == Some(Profit.Medium),
      )
      TestKit.check(
        "a missing tagPriceUsd decodes to None",
        Array.get(decoded.items, 0)->Option.flatMap(i => i.tagPriceUsd) == None,
      )
    }
  | Error(_) => TestKit.check("a reply with no scale-ref fields still decodes", false)
  }

  // shipClass and tagPriceUsd decode (docs/spec-profit.md, Shape): a known
  // class decodes to its variant, an unknown class falls back to Medium, a
  // number decodes to Some, and an explicit null decodes to None.
  let shipClassAndTag = Json.obj([
    (
      "content",
      Json.arr([
        Json.obj([
          ("type", Json.str("text")),
          (
            "text",
            Json.str(
              "{\"items\": [{\"name\": \"Tagged item\", \"maker\": \"\", \"query\": \"tagged item\", \"estimateLowUsd\": 1, \"estimateHighUsd\": 2, \"basis\": \"guess\", \"confidence\": 0.1, \"sources\": [], \"shipClass\": \"large\", \"tagPriceUsd\": 4}, {\"name\": \"Bogus class item\", \"maker\": \"\", \"query\": \"bogus class item\", \"estimateLowUsd\": 1, \"estimateHighUsd\": 2, \"basis\": \"guess\", \"confidence\": 0.1, \"sources\": [], \"shipClass\": \"bogus\", \"tagPriceUsd\": null}]}",
            ),
          ),
        ]),
      ]),
    ),
    ("usage", Json.obj([("input_tokens", Json.num(1.0)), ("output_tokens", Json.num(1.0))])),
  ])
  switch ClaudeClient.decodeResponse(shipClassAndTag) {
  | Ok(decoded) => {
      TestKit.check(
        "shipClass \"large\" decodes to Large",
        Array.get(decoded.items, 0)->Option.map(i => i.shipClass) == Some(Profit.Large),
      )
      TestKit.check(
        "tagPriceUsd 4 decodes to Some(4.)",
        Array.get(decoded.items, 0)->Option.flatMap(i => i.tagPriceUsd) == Some(4.0),
      )
      TestKit.check(
        "an unknown shipClass \"bogus\" falls back to Medium",
        Array.get(decoded.items, 1)->Option.map(i => i.shipClass) == Some(Profit.Medium),
      )
      TestKit.check(
        "a null tagPriceUsd decodes to None",
        Array.get(decoded.items, 1)->Option.flatMap(i => i.tagPriceUsd) == None,
      )
    }
  | Error(_) => TestKit.check("shipClass and tagPriceUsd reply decodes", false)
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
  | Error(ClaudeClient.CutOff(_)) => TestKit.check("stop_reason max_tokens gives CutOff", true)
  | _ => TestKit.check("stop_reason max_tokens should give CutOff", false)
  }

  switch ClaudeClient.parseClaudeJson(fixtureJson) {
  | Ok(decoded) =>
    TestKit.check("parseClaudeJson still decodes a normal reply", Array.length(decoded.items) == 3)
  | Error(_) => TestKit.check("parseClaudeJson should decode a normal reply", false)
  }
}
