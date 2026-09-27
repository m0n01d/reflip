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
    ~mode=ClaudeClient.Haul({gemMinUsd: 20.0, width: 800, height: 600}),
  )
  let haulSerialized = JSON.stringify(haulRequestJson)
  // The haul prompt now asks for a box too (docs/spec-item-boxes.mds
  // follow-up), so its request states the photo size exactly like the scene
  // request does.
  TestKit.check(
    "scene request states the photo size",
    String.includes(serialized, "800 pixels wide and 600 pixels tall"),
  )
  TestKit.check(
    "haul request states the photo size",
    String.includes(haulSerialized, "800 pixels wide and 600 pixels tall"),
  )

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

  // Stall fix (docs/stall-fix.md): the web_search tool searches directly,
  // never from a code step, on both the scene and the haul request.
  let checkWebSearchTool = (label: string, body: JSON.t) => {
    let tool = Json.arrayField(body, "tools")->Option.getOr([])->Array.get(0)
    let callers =
      tool
      ->Option.flatMap(t => Json.arrayField(t, "allowed_callers"))
      ->Option.getOr([])
      ->Array.filterMap(JSON.Decode.string)
    let blocked =
      tool
      ->Option.flatMap(t => Json.arrayField(t, "blocked_domains"))
      ->Option.getOr([])
      ->Array.filterMap(JSON.Decode.string)
    TestKit.check(label ++ " web_search tool allows only direct callers", callers == ["direct"])
    TestKit.check(label ++ " web_search tool blocks ebay.com", blocked == ["ebay.com"])
  }
  checkWebSearchTool("scene", requestJson)
  checkWebSearchTool("haul", haulRequestJson)

  // Item schema (docs/stream-spike.md, recommendation 7): box comes right
  // after name, so each box streams about 1 s before the rest of its item.
  let itemSchemaKeys =
    SystemPrompt.itemSchema
    ->Json.field("properties")
    ->Option.flatMap(JSON.Decode.object)
    ->Option.map(Dict.keysToArray)
    ->Option.getOr([])
  TestKit.check(
    "item schema properties start with name, then box",
    Array.get(itemSchemaKeys, 0) == Some("name") && Array.get(itemSchemaKeys, 1) == Some("box"),
  )

  // Place (haul-map step 7): a haul's place never reaches the Claude request
  // body or the haul digest. CLAUDE.md privacy rule -- log no body and no
  // coordinates -- covers every place the brain builds text from.
  TestKit.section("Guard: haul place stays out of the Claude request and the digest")

  let placeDb = Store.openAt(":memory:")
  let placeHaul = Store.createHaul(
    placeDb,
    ~haulId="place-guard-haul",
    ~name=None,
    ~now="2026-09-26T00:00:00.000Z",
  )
  let placeScene = Store.addScene(
    placeDb,
    ~haulId=placeHaul.haulId,
    ~clientId="place-guard-client",
    ~sceneId="place-guard-scene",
    ~photoPath=Node.Path.join([fixturesDir, "table.jpg"]),
    ~now="2026-09-26T00:00:00.000Z",
    ~imageWidth=None,
    ~imageHeight=None,
  )
  let placeInput: Types.place = {
    lat: 47.6180431,
    lon: -122.3514229,
    accuracyM: Some(13.37),
    source: Gps,
    at: "2026-09-26T00:00:00.000Z",
  }
  let storedPlace = Store.setPlace(placeDb, ~haulId=placeHaul.haulId, ~place=placeInput)

  switch storedPlace {
  | None => TestKit.check("place guard: setPlace found the haul it just created", false)
  | Some(place) => {
      let storedJson = JSON.stringify(Json.obj([("place", Types.encodePlace(place))]))
      TestKit.check(
        "stored haul's place JSON contains the gps lat (proves the search methodology can fail)",
        String.includes(storedJson, "47.618"),
      )

      let placeConfig: Config.t = {
        port: 0,
        fixtures: true,
        dataDir: fixturesDir,
        fixturesDir,
        anthropicApiKey: None,
        ebayClientId: None,
        ebayClientSecret: None,
        structuredOutput: true,
        distIndexPath: Node.Path.join([Node.Process.cwd(), "dist/index.html"]),
        distDir: Node.Path.join([Node.Process.cwd(), "dist"]),
        haulConcurrency: 4,
        haulMaxUsd: 10.0,
        haulGemMinUsd: 20.0,
      }
      let placeWorker = HaulWorker.make(
        ~config=placeConfig,
        ~store=placeDb,
        ~onDrained=_ => Promise.resolve(),
      )

      switch HaulWorker.requestBodyFor(placeWorker, placeScene) {
      | Error(msg) =>
        TestKit.check(
          "place guard: requestBodyFor reads the fixture photo (" ++ msg ++ ")",
          false,
        )
      | Ok(body) => {
          let bodyJson = JSON.stringify(body)
          TestKit.check(
            "Claude request body excludes the gps lat",
            !String.includes(bodyJson, "47.618"),
          )
          TestKit.check(
            "Claude request body excludes the gps lon",
            !String.includes(bodyJson, "122.351"),
          )
          TestKit.check(
            "Claude request body excludes the gps accuracy",
            !String.includes(bodyJson, "13.37"),
          )
        }
      }

      let placeCounts: Store.counts = {queued: 0, running: 0, done: 0, failed: 0}
      let (digestInput, _images) = HaulEmail.digestInputOf(
        placeConfig,
        {...placeHaul, place: Some(place)},
        [placeScene],
        [],
        placeCounts,
        Dict.make(),
      )
      let digest = Digest.make(digestInput, ~cidFor=id => id)
      let digestText = digest.subject ++ digest.text ++ digest.html
      TestKit.check("haul digest excludes the gps lat", !String.includes(digestText, "47.618"))
      TestKit.check("haul digest excludes the gps lon", !String.includes(digestText, "122.351"))
      TestKit.check(
        "haul digest excludes the gps accuracy",
        !String.includes(digestText, "13.37"),
      )
    }
  }
}
