// Guard: build the Claude request body in fixture mode, serialize it, and
// make sure it contains no title and no price from the eBay fixtures.
// CLAUDE.md hard design rule 1 — eBay numbers never reach the model.

let run = () => {
  TestKit.section("Guard: eBay numbers never reach the model")

  let fixturesDir = Node.Path.join([Node.Process.cwd(), "tests/fixtures"])
  let ebayJson = EbayClient.searchFixture(fixturesDir, 0)
  let items = Json.arrayField(ebayJson, "itemSummaries")->Option.getOr([])
  let titles = Array.filterMap(items, item => Json.stringField(item, "title"))
  let prices = Array.filterMap(items, item =>
    Json.field(item, "price")->Option.flatMap(p => Json.stringField(p, "value"))
  )

  TestKit.check("fixture actually has titles to check against", Array.length(titles) > 0)
  TestKit.check("fixture actually has prices to check against", Array.length(prices) > 0)

  let requestJson = ClaudeClient.buildRequestBody(
    ~model="claude-sonnet-5",
    ~imageBase64="ZmFrZQ==",
    ~structuredOutput=true,
    ~mode=ClaudeClient.Scene({width: 800, height: 600}),
  )
  let serialized = JSON.stringify(requestJson)

  Array.forEach(titles, title =>
    TestKit.check(
      "request body excludes eBay title \"" ++ title ++ "\"",
      !String.includes(serialized, title),
    )
  )
  Array.forEach(prices, price =>
    TestKit.check(
      "request body excludes eBay price " ++ price,
      !String.includes(serialized, price),
    )
  )

  // Streaming (M1 spike): ClaudeStream.addStreamFlag must add exactly one
  // field, "stream": true, and change nothing else about the body.
  switch (JSON.Decode.object(requestJson), JSON.Decode.object(ClaudeStream.addStreamFlag(requestJson))) {
  | (Some(plainDict), Some(streamedDict)) =>
      let plainKeys = Dict.keysToArray(plainDict)
      let streamedKeys = Dict.keysToArray(streamedDict)
      TestKit.check(
        "streamed body adds exactly one key over the plain body",
        Array.length(streamedKeys) == Array.length(plainKeys) + 1,
      )
      TestKit.check(
        "stream field on the streamed body is true",
        Dict.get(streamedDict, "stream")->Option.map(j => JSON.stringify(j)) ==
          Some(JSON.stringify(JSON.Encode.bool(true))),
      )
      let sameExceptStream = Array.every(plainKeys, key =>
        Dict.get(streamedDict, key)->Option.map(j => JSON.stringify(j)) ==
          Dict.get(plainDict, key)->Option.map(j => JSON.stringify(j))
      )
      TestKit.check(
        "streamed body equals the plain body plus \"stream\": true",
        sameExceptStream,
      )
  | _ => TestKit.check("both the plain and streamed bodies decode as JSON objects", false)
  }

  // Haul mode (step 4): same guard, plus the gem-threshold prompt and its
  // own schema must not leak eBay numbers either.
  let haulRequestJson = ClaudeClient.buildRequestBody(
    ~model="claude-sonnet-5",
    ~imageBase64="ZmFrZQ==",
    ~structuredOutput=true,
    ~mode=ClaudeClient.Haul(20.0),
  )
  let haulSerialized = JSON.stringify(haulRequestJson)
  // Only the scene request states the photo size; the haul prompt asks for
  // no box, so its request stays as it was before item boxes.
  TestKit.check(
    "scene request states the photo size",
    String.includes(serialized, "800 pixels wide and 600 pixels tall"),
  )
  TestKit.check("haul request states no photo size", !String.includes(haulSerialized, "pixels wide"))

  Array.forEach(titles, title =>
    TestKit.check(
      "haul request body excludes eBay title \"" ++ title ++ "\"",
      !String.includes(haulSerialized, title),
    )
  )
  Array.forEach(prices, price =>
    TestKit.check(
      "haul request body excludes eBay price " ++ price,
      !String.includes(haulSerialized, price),
    )
  )
  TestKit.check(
    "haul request still blocks ebay.com",
    String.includes(haulSerialized, "blocked_domains") && String.includes(haulSerialized, "ebay.com"),
  )
  TestKit.check(
    "haul system text names the $20 gem threshold",
    String.includes(haulSerialized, "$20"),
  )
}
