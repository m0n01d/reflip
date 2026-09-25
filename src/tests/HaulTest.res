// Haul mode: routes, worker, restart recovery, 429 wait and budget stop.
// Per docs/spec-haul-mode.md "Step 3: brain queue". Every case gets its own
// tmp dataDir and closes its server (and store) before the next case, and
// every wait below is bounded by pollUntil's ~timeoutMs.

let cwd = Node.Process.cwd()
let fixturesDir = Node.Path.join([cwd, "tests/fixtures"])

// A haul scene's photo goes through HaulWorker.runScene, which reads its
// width and height with JpegSize.dimensions before ever calling Claude
// (Server.res's handleScene does the same for the M0 flow). A placeholder
// string body isn't a real JPEG, so any scene that must reach "valued"
// posts or writes these real bytes instead.
let tablePhotoBuffer = Node.Fs.readFileBuffer(Node.Path.join([fixturesDir, "table.jpg"]))

let tmpDataDir = (): string =>
  Node.Path.join([Node.Os.tmpdir(), "reflip-haul-test-" ++ Node.Crypto.randomUUID()])

let sleep = (ms: int): promise<unit> =>
  Promise.make((resolve, _reject) => Node.Timer.setTimeout(() => resolve(), ms))

// Bounded poll: calls `check` every 100 ms until it returns true or
// `timeoutMs` passes. Returns whether it succeeded — never loops forever.
let pollUntil = async (~timeoutMs: int, check: unit => promise<bool>): bool => {
  let deadline = Date.now() +. Int.toFloat(timeoutMs)
  let succeeded = ref(false)
  let keepGoing = ref(true)
  while keepGoing.contents {
    if await check() {
      succeeded := true
      keepGoing := false
    } else if Date.now() >= deadline {
      keepGoing := false
    } else {
      await sleep(100)
    }
  }
  succeeded.contents
}

let getJson = async (url: string): (int, JSON.t) => {
  let resp = await Fetch.fetch(url, ~init={Fetch.method: "GET"})
  (Fetch.status(resp), await Fetch.json(resp))
}

let postJson = async (url: string, body: JSON.t): (int, JSON.t) => {
  let resp = await Fetch.fetch(
    url,
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "application/json")]),
      body: JSON.stringify(body),
    },
  )
  (Fetch.status(resp), await Fetch.json(resp))
}

let postEmpty = async (url: string): int => {
  let resp = await Fetch.fetch(url, ~init={Fetch.method: "POST"})
  Fetch.status(resp)
}

let postScene = async (base: string, haulId: string, clientId: string): (int, JSON.t) => {
  let resp = await Fetch.fetchBuffer(
    base ++ "/api/hauls/" ++ haulId ++ "/scenes",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "image/jpeg"), ("x-client-id", clientId)]),
      body: tablePhotoBuffer,
    },
  )
  (Fetch.status(resp), await Fetch.json(resp))
}

let countsOf = (statusJson: JSON.t): JSON.t =>
  Json.field(statusJson, "counts")->Option.getOr(Json.obj([]))

let valuedCount = (statusJson: JSON.t): option<int> => Json.intField(countsOf(statusJson), "valued")

let baseConfig = (~dataDir: string, ~fixtures: bool): Config.t => {
  Config.port: 0,
  fixtures,
  dataDir,
  fixturesDir,
  anthropicApiKey: None,
  ebayClientId: None,
  ebayClientSecret: None,
  structuredOutput: true,
  distIndexPath: Node.Path.join([cwd, "dist/index.html"]),
  distDir: Node.Path.join([cwd, "dist"]),
  haulConcurrency: 4,
  haulMaxUsd: 10.0,
  haulGemMinUsd: 20.0,
}

// -- Claude haul fixture's per-scene cost, hand-computed against Pricing.res
// (haul mode reads tests/fixtures/claude-haul.json, step 4). 2000 input
// tok, 300 output tok, 1 web search, on claude-sonnet-5:
// 2000*2e-6 + 300*10e-6 + 1*0.01 = 0.004 + 0.003 + 0.01 = 0.017.
let fixtureSceneCostUsd = 0.017

let run = async () => {
  // -- 1. FIXTURES=1 happy path ----------------------------------------------
  TestKit.section("Haul: FIXTURES=1 happy path")

  let dataDir1 = tmpDataDir()
  let config1 = baseConfig(~dataDir=dataDir1, ~fixtures=true)
  let {Server.server: server1, port: port1, store: store1} = await Server.start(config1)
  let base1 = "http://127.0.0.1:" ++ Int.toString(port1)

  let (createStatus, createJson) = await postJson(
    base1 ++ "/api/hauls",
    Json.obj([("name", Json.str("Goodwill"))]),
  )
  TestKit.check("POST /api/hauls responds 201", createStatus == 201)
  let haulId1 = Json.stringField(createJson, "haulId")->Option.getOr("")
  TestKit.check("create reply has a haulId", haulId1 != "")
  TestKit.check("create reply names the store", Json.stringField(createJson, "name") == Some("Goodwill"))

  let (s1, j1) = await postScene(base1, haulId1, "client-a")
  TestKit.check("first scene 202", s1 == 202)
  let sceneId1 = Json.stringField(j1, "sceneId")->Option.getOr("")

  let (s2, _) = await postScene(base1, haulId1, "client-b")
  TestKit.check("second scene 202", s2 == 202)
  let (s3, _) = await postScene(base1, haulId1, "client-c")
  TestKit.check("third scene 202", s3 == 202)

  let (s1Retry, j1Retry) = await postScene(base1, haulId1, "client-a")
  TestKit.check("a repeated clientId is 202", s1Retry == 202)
  TestKit.check(
    "a repeated clientId returns the same sceneId",
    Json.stringField(j1Retry, "sceneId") == Some(sceneId1),
  )
  TestKit.check("a repeated clientId is marked duplicate", Json.boolField(j1Retry, "duplicate") == Some(true))

  TestKit.check(
    "the scene's photo landed on disk",
    Node.Fs.existsSync(Node.Path.join([dataDir1, "photos", sceneId1 ++ ".jpg"])),
  )

  // The upload read the real fixture JPEG's size (table.jpg is 64x48) and
  // stored it on the scene row — docs/spec-haul-mode.md "The routes",
  // GET /api/hauls/:id/scenes.
  switch Store.sceneByClient(store1, ~haulId=haulId1, ~clientId="client-a") {
  | Some(s) =>
    TestKit.check(
      "the upload stores the photo's size on the scene",
      s.imageWidth == Some(64) && s.imageHeight == Some(48),
    )
  | None => TestKit.check("sceneByClient found the uploaded scene", false)
  }

  // GET /api/scenes/:id/photo serves the same bytes back, with the two
  // headers the spec asks for.
  let photoResp = await Fetch.fetch(base1 ++ "/api/scenes/" ++ sceneId1 ++ "/photo")
  TestKit.check("GET the scene's photo responds 200", Fetch.status(photoResp) == 200)
  TestKit.check(
    "the photo response is image/jpeg",
    Fetch.getHeader(Fetch.responseHeaders(photoResp), "content-type")->Nullable.toOption ==
      Some("image/jpeg"),
  )
  TestKit.check(
    "the photo response is cacheable, private and immutable",
    Fetch.getHeader(Fetch.responseHeaders(photoResp), "cache-control")->Nullable.toOption ==
      Some("private, max-age=31536000, immutable"),
  )
  let photoBuf = Node.Buffer.fromArrayBuffer(await Fetch.arrayBuffer(photoResp))
  TestKit.check(
    "the photo bytes match what was uploaded",
    Node.Buffer.toStringWithEncoding(photoBuf, "base64") ==
      Node.Buffer.toStringWithEncoding(tablePhotoBuffer, "base64"),
  )

  let reachedValued3 = await pollUntil(~timeoutMs=5000, async () => {
    let (_status, json) = await getJson(base1 ++ "/api/hauls/" ++ haulId1)
    valuedCount(json) == Some(3)
  })
  TestKit.check("all 3 scenes reach valued within 5 s", reachedValued3)

  let (_status, statusJson1) = await getJson(base1 ++ "/api/hauls/" ++ haulId1)
  let gems1 = Json.arrayField(statusJson1, "gems")->Option.getOr([])
  // The haul fixture lists 2 gems (>= the $20 default) and 1 sub-threshold
  // item per scene; the third item proves the threshold is code, not the
  // prompt (HaulStatus.gemsOf filters on estimateHighUsd, the prompt only
  // asks the model to skip listing items below it).
  TestKit.check(
    "gems: 2 items/scene clear the $20 threshold x 3 scenes",
    Array.length(gems1) == 6,
  )
  let hasEbay = Array.every(gems1, g => Json.field(g, "ebay") != Some(JSON.Encode.null))
  TestKit.check("every gem got its eBay stats (fixture mode)", hasEbay)
  let hasWhere = Array.every(gems1, g => Json.stringField(g, "where")->Option.isSome)
  TestKit.check("every gem carries a where", hasWhere)

  // Each gem's status JSON carries its find's box, and the size of the
  // photo it came from (table.jpg is 64x48 — table.jpg's own README, and
  // ServerTest.res's own check of the M0 /api/scene reply against it).
  let gemByName = (gems: array<JSON.t>, name: string): option<JSON.t> =>
    Array.find(gems, g => Json.stringField(g, "name") == Some(name))

  switch gemByName(gems1, "Brass table lamp") {
  | Some(g) => {
      let box = Json.field(g, "box")->Option.flatMap(Shared.decodeBox)
      TestKit.check(
        "the lamp gem's status JSON carries the fixture's box",
        box == Some({Types.x1: 2, y1: 4, x2: 20, y2: 30}),
      )
      TestKit.check(
        "the lamp gem's status JSON carries the photo size",
        Json.intField(g, "imageWidth") == Some(64) && Json.intField(g, "imageHeight") == Some(48),
      )
    }
  | None => TestKit.check("found the lamp gem in the status JSON", false)
  }
  switch gemByName(gems1, "Griswold cast iron skillet") {
  | Some(g) =>
    TestKit.check(
      "the skillet gem's status JSON has a null box, its fixture box was degenerate",
      Json.field(g, "box") == Some(JSON.Encode.null),
    )
  | None => TestKit.check("found the skillet gem in the status JSON", false)
  }

  TestKit.approx(
    "cost is 3 x the fixture's per-scene cost",
    Json.floatField(statusJson1, "costUsd")->Option.getOr(0.0),
    fixtureSceneCostUsd *. 3.0,
    ~eps=0.001,
  )
  // otherCount: each scene's own otherCount (12) plus the one sub-threshold
  // find per scene that HaulStatus counts as "other" instead of a gem —
  // 3 scenes x (12 + 1) = 39.
  TestKit.check(
    "status otherCount is 3 x (12 + 1)",
    Json.intField(statusJson1, "otherCount") == Some(39),
  )

  // Each scene's 3 finds come from the same claude-haul.json fixture: the
  // lamp and the brooch each carry a box in table.jpg's 64x48 pixels
  // (Box.decode passes them through unchanged, since the high tier doesn't
  // resize a photo that small). The skillet's box is degenerate on purpose
  // (x2 <= x1), so Box.decode drops it and that find stores no box — the
  // skillet is a gem (its estimateHighUsd is above the $20 threshold), so
  // this is the fixture that proves a gem with no box works end to end.
  let finds1 = Store.findsOf(store1, haulId1)
  TestKit.check("all 9 finds (3 scenes x 3 items) were stored", Array.length(finds1) == 9)
  let lampFinds = Array.filter(finds1, f => f.name == "Brass table lamp")
  let skilletFinds = Array.filter(finds1, f => f.name == "Griswold cast iron skillet")
  let broochFinds = Array.filter(finds1, f => f.name == "Costume jewelry brooch")
  TestKit.check(
    "every lamp find stores the fixture's box",
    Array.length(lampFinds) == 3 &&
      Array.every(lampFinds, f => f.box == Some({Types.x1: 2, y1: 4, x2: 20, y2: 30})),
  )
  TestKit.check(
    "every skillet find has no box, its fixture box is degenerate",
    Array.length(skilletFinds) == 3 && Array.every(skilletFinds, f => f.box == None),
  )
  TestKit.check(
    "every brooch find stores the fixture's box",
    Array.length(broochFinds) == 3 &&
      Array.every(broochFinds, f => f.box == Some({Types.x1: 44, y1: 32, x2: 60, y2: 46})),
  )

  let doneStatus = await postEmpty(base1 ++ "/api/hauls/" ++ haulId1 ++ "/done")
  TestKit.check("POST done responds 200", doneStatus == 200)
  let (_status, doneJson) = await getJson(base1 ++ "/api/hauls/" ++ haulId1)
  TestKit.check("done sets doneAt", Json.stringField(doneJson, "doneAt")->Option.isSome)

  // onDrained fires exactly once for a drained haul, even if something (the
  // /done route, and the worker after every scene) calls checkDrained more
  // than once for it — a direct check of HaulWorker's in-memory guard,
  // against its own in-memory store so nothing here touches the network.
  let drainedCount = ref(0)
  let guardStore = Store.openAt(":memory:")
  let guardWorker = HaulWorker.make(~config=config1, ~store=guardStore, ~onDrained=_haulId => {
    drainedCount := drainedCount.contents + 1
    Promise.resolve()
  })
  Store.createHaul(guardStore, ~haulId="drain-haul", ~name=None, ~now="2026-09-24T00:00:00.000Z")->ignore
  Store.markDone(guardStore, ~haulId="drain-haul", ~now="2026-09-24T00:00:01.000Z")
  HaulWorker.checkDrained(guardWorker, "drain-haul")
  HaulWorker.checkDrained(guardWorker, "drain-haul")
  HaulWorker.checkDrained(guardWorker, "drain-haul")
  await sleep(20)
  TestKit.check("onDrained fires exactly once for a drained haul", drainedCount.contents == 1)
  Store.close(guardStore)

  Node.HttpServer.close(server1, () => ())
  Store.close(store1)

  // -- 2. Budget stop ---------------------------------------------------------
  TestKit.section("Haul: budget stop")

  let dataDir2 = tmpDataDir()
  let config2 = {
    ...baseConfig(~dataDir=dataDir2, ~fixtures=true),
    Config.haulConcurrency: 1,
    haulMaxUsd: 0.01,
  }
  let {Server.server: server2, port: port2, store: store2} = await Server.start(config2)
  let base2 = "http://127.0.0.1:" ++ Int.toString(port2)

  let (_status, createJson2) = await postJson(base2 ++ "/api/hauls", Json.obj([]))
  let haulId2 = Json.stringField(createJson2, "haulId")->Option.getOr("")
  let _ = await postScene(base2, haulId2, "client-a")
  let _ = await postScene(base2, haulId2, "client-b")
  let _ = await postScene(base2, haulId2, "client-c")

  let stopped2 = await pollUntil(~timeoutMs=5000, async () => {
    let (_status, json) = await getJson(base2 ++ "/api/hauls/" ++ haulId2)
    Json.stringField(json, "stopReason")->Option.isSome
  })
  TestKit.check("the haul stops within 5 s of the budget being reached", stopped2)

  let (_status, statusJson2) = await getJson(base2 ++ "/api/hauls/" ++ haulId2)
  TestKit.check(
    "the stop reason names the budget",
    switch Json.stringField(statusJson2, "stopReason") {
    | Some(r) => String.includes(r, "budget reached")
    | None => false
    },
  )
  TestKit.check(
    "the stop reason shows dollars with two decimals",
    switch Json.stringField(statusJson2, "stopReason") {
    | Some(r) => RegExp.test(/budget reached: \$\d+\.\d\d of \$\d+\.\d\d$/, r)
    | None => false
    },
  )
  TestKit.check("only the first scene was valued", Json.intField(countsOf(statusJson2), "valued") == Some(1))
  TestKit.check("the other two scenes stay queued", Json.intField(countsOf(statusJson2), "queued") == Some(2))

  Node.HttpServer.close(server2, () => ())
  Store.close(store2)

  // -- 3. 429: stub Claude, always rate-limited --------------------------------
  TestKit.section("Haul: 429 stops the haul after 3 in a row")

  let stubAlways429 = Node.HttpServer.createServer((_req, res) => {
    Node.HttpServer.writeHead(res, 429, Dict.fromArray([("Content-Type", "application/json")]))
    Node.HttpServer.endWithBody(res, `{"type":"error","error":{"message":"rate limited"}}`)
  })
  let stubAlways429Port = await Promise.make((resolve, _reject) =>
    Node.HttpServer.listen(stubAlways429, 0, "127.0.0.1", () =>
      resolve(Node.HttpServer.address(stubAlways429).port)
    )
  )
  let dataDir3a = tmpDataDir()
  let config3a = {
    ...baseConfig(~dataDir=dataDir3a, ~fixtures=false),
    Config.anthropicApiKey: Some("test-key-not-real"),
    haulConcurrency: 1,
    claudeUrl: "http://127.0.0.1:" ++ Int.toString(stubAlways429Port) ++ "/v1/messages",
    claudeTimeoutMs: 5000,
    haulRetryMs: 20,
  }
  let {Server.server: server3a, port: port3a, store: store3a} = await Server.start(config3a)
  let base3a = "http://127.0.0.1:" ++ Int.toString(port3a)
  let (_status, createJson3a) = await postJson(base3a ++ "/api/hauls", Json.obj([]))
  let haulId3a = Json.stringField(createJson3a, "haulId")->Option.getOr("")
  let _ = await postScene(base3a, haulId3a, "client-a")

  let stopped3a = await pollUntil(~timeoutMs=5000, async () => {
    let (_status, json) = await getJson(base3a ++ "/api/hauls/" ++ haulId3a)
    Json.stringField(json, "stopReason")->Option.isSome
  })
  TestKit.check("always-429 stops the haul within 5 s", stopped3a)
  let (_status, statusJson3a) = await getJson(base3a ++ "/api/hauls/" ++ haulId3a)
  TestKit.check(
    "the stop reason names 429 and the 3-in-a-row rule",
    switch Json.stringField(statusJson3a, "stopReason") {
    | Some(r) => String.includes(r, "429") && String.includes(r, "3 Claude failures in a row")
    | None => false
    },
  )
  TestKit.check("the scene stays queued, not failed", Json.intField(countsOf(statusJson3a), "queued") == Some(1))
  TestKit.check("nothing was marked failed", Json.intField(countsOf(statusJson3a), "failed") == Some(0))

  Node.HttpServer.close(server3a, () => ())
  Node.HttpServer.close(stubAlways429, () => ())
  Store.close(store3a)

  // -- 3b. 429 once, then a real fixture reply ---------------------------------
  TestKit.section("Haul: 429 once then 200 still values the scene")

  let claudeSceneFixture = Node.Fs.readFileUtf8(
    Node.Path.join([fixturesDir, "claude-scene.json"]),
    "utf8",
  )
  let attempts = ref(0)
  let stubOnce429 = Node.HttpServer.createServer((_req, res) => {
    attempts := attempts.contents + 1
    if attempts.contents == 1 {
      Node.HttpServer.writeHead(res, 429, Dict.fromArray([("Content-Type", "application/json")]))
      Node.HttpServer.endWithBody(res, `{"type":"error","error":{"message":"rate limited"}}`)
    } else {
      Node.HttpServer.writeHead(res, 200, Dict.fromArray([("Content-Type", "application/json")]))
      Node.HttpServer.endWithBody(res, claudeSceneFixture)
    }
  })
  let stubOnce429Port = await Promise.make((resolve, _reject) =>
    Node.HttpServer.listen(stubOnce429, 0, "127.0.0.1", () =>
      resolve(Node.HttpServer.address(stubOnce429).port)
    )
  )
  let dataDir3b = tmpDataDir()
  let config3b = {
    ...baseConfig(~dataDir=dataDir3b, ~fixtures=false),
    Config.anthropicApiKey: Some("test-key-not-real"),
    haulConcurrency: 1,
    claudeUrl: "http://127.0.0.1:" ++ Int.toString(stubOnce429Port) ++ "/v1/messages",
    claudeTimeoutMs: 5000,
    haulRetryMs: 20,
  }
  let {Server.server: server3b, port: port3b, store: store3b} = await Server.start(config3b)
  let base3b = "http://127.0.0.1:" ++ Int.toString(port3b)
  let (_status, createJson3b) = await postJson(base3b ++ "/api/hauls", Json.obj([]))
  let haulId3b = Json.stringField(createJson3b, "haulId")->Option.getOr("")
  let _ = await postScene(base3b, haulId3b, "client-a")

  let valued3b = await pollUntil(~timeoutMs=5000, async () => {
    let (_status, json) = await getJson(base3b ++ "/api/hauls/" ++ haulId3b)
    valuedCount(json) == Some(1)
  })
  TestKit.check("a 429 then a 200 still values the scene within 5 s", valued3b)

  Node.HttpServer.close(server3b, () => ())
  Node.HttpServer.close(stubOnce429, () => ())
  Store.close(store3b)

  // -- 4. Any other error, 3 times ---------------------------------------------
  TestKit.section("Haul: a 500 x3 fails the scenes and stops the haul")

  let stub500 = Node.HttpServer.createServer((_req, res) => {
    Node.HttpServer.writeHead(res, 500, Dict.fromArray([("Content-Type", "application/json")]))
    Node.HttpServer.endWithBody(res, `{"type":"error","error":{"message":"internal error"}}`)
  })
  let stub500Port = await Promise.make((resolve, _reject) =>
    Node.HttpServer.listen(stub500, 0, "127.0.0.1", () => resolve(Node.HttpServer.address(stub500).port))
  )
  let dataDir4 = tmpDataDir()
  let config4 = {
    ...baseConfig(~dataDir=dataDir4, ~fixtures=false),
    Config.anthropicApiKey: Some("test-key-not-real"),
    haulConcurrency: 1,
    claudeUrl: "http://127.0.0.1:" ++ Int.toString(stub500Port) ++ "/v1/messages",
    claudeTimeoutMs: 5000,
  }
  let {Server.server: server4, port: port4, store: store4} = await Server.start(config4)
  let base4 = "http://127.0.0.1:" ++ Int.toString(port4)
  let (_status, createJson4) = await postJson(base4 ++ "/api/hauls", Json.obj([]))
  let haulId4 = Json.stringField(createJson4, "haulId")->Option.getOr("")
  let _ = await postScene(base4, haulId4, "client-a")
  let _ = await postScene(base4, haulId4, "client-b")
  let _ = await postScene(base4, haulId4, "client-c")

  let stopped4 = await pollUntil(~timeoutMs=5000, async () => {
    let (_status, json) = await getJson(base4 ++ "/api/hauls/" ++ haulId4)
    Json.stringField(json, "stopReason")->Option.isSome
  })
  TestKit.check("3 non-429 failures in a row stop the haul within 5 s", stopped4)
  let (_status, statusJson4) = await getJson(base4 ++ "/api/hauls/" ++ haulId4)
  TestKit.check("all 3 scenes are marked failed", Json.intField(countsOf(statusJson4), "failed") == Some(3))
  TestKit.check("the failed list names all 3 scenes", Array.length(Json.arrayField(statusJson4, "failed")->Option.getOr([])) == 3)

  Node.HttpServer.close(server4, () => ())
  Node.HttpServer.close(stub500, () => ())
  Store.close(store4)

  // -- 5. Restart recovers a running scene -------------------------------------
  TestKit.section("Haul: restart resets a running scene back to queued")

  let dataDir5 = tmpDataDir()
  Node.Fs.mkdirSync(dataDir5, {recursive: true})
  let preStore = Store.openAt(Node.Path.join([dataDir5, "reflip.db"]))
  let haulId5 = "haul-restart"
  Store.createHaul(preStore, ~haulId=haulId5, ~name=None, ~now="2026-09-24T00:00:00.000Z")->ignore
  Node.Fs.mkdirSync(Node.Path.join([dataDir5, "photos"]), {recursive: true})
  let photoPath5 = Node.Path.join([dataDir5, "photos", "scene-restart.jpg"])
  Node.Fs.writeFileBuffer(photoPath5, tablePhotoBuffer)
  let scene5 = Store.addScene(
    preStore,
    ~haulId=haulId5,
    ~clientId="client-restart",
    ~sceneId="scene-restart",
    ~photoPath=photoPath5,
    ~now="2026-09-24T00:00:01.000Z",
    ~imageWidth=None,
    ~imageHeight=None,
  )
  Store.setStatus(preStore, ~sceneId=scene5.sceneId, Store.Running)
  Store.close(preStore)

  let config5 = baseConfig(~dataDir=dataDir5, ~fixtures=true)
  let {Server.server: server5, port: port5, store: store5} = await Server.start(config5)
  let base5 = "http://127.0.0.1:" ++ Int.toString(port5)

  let valued5 = await pollUntil(~timeoutMs=5000, async () => {
    let (_status, json) = await getJson(base5 ++ "/api/hauls/" ++ haulId5)
    valuedCount(json) == Some(1)
  })
  TestKit.check("the running-on-disk scene gets valued after a restart", valued5)

  Node.HttpServer.close(server5, () => ())
  Store.close(store5)

  // -- 6. Route errors ----------------------------------------------------------
  TestKit.section("Haul: route errors")

  let dataDir6 = tmpDataDir()
  let config6 = baseConfig(~dataDir=dataDir6, ~fixtures=true)
  let {Server.server: server6, port: port6, store: store6} = await Server.start(config6)
  let base6 = "http://127.0.0.1:" ++ Int.toString(port6)

  let (getMissingStatus, _) = await getJson(base6 ++ "/api/hauls/does-not-exist")
  TestKit.check("GET an unknown haul is 404", getMissingStatus == 404)

  let (postMissingStatus, _) = await postScene(base6, "does-not-exist", "client-a")
  TestKit.check("POST a scene to an unknown haul is 404", postMissingStatus == 404)

  let (_status, createJson6) = await postJson(base6 ++ "/api/hauls", Json.obj([]))
  let haulId6 = Json.stringField(createJson6, "haulId")->Option.getOr("")

  let noClientIdResp = await Fetch.fetch(
    base6 ++ "/api/hauls/" ++ haulId6 ++ "/scenes",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "image/jpeg")]),
      body: "fake-jpeg-bytes",
    },
  )
  TestKit.check("POST a scene with no x-client-id header is 400", Fetch.status(noClientIdResp) == 400)

  let emptyBodyResp = await Fetch.fetch(
    base6 ++ "/api/hauls/" ++ haulId6 ++ "/scenes",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "image/jpeg"), ("x-client-id", "client-empty")]),
      body: "",
    },
  )
  TestKit.check("POST a scene with an empty body is 400", Fetch.status(emptyBodyResp) == 400)

  let doneStatus6 = await postEmpty(base6 ++ "/api/hauls/" ++ haulId6 ++ "/done")
  TestKit.check("POST done on a fresh haul is 200", doneStatus6 == 200)

  let (afterDoneStatus, _) = await postScene(base6, haulId6, "client-after-done")
  TestKit.check("POST a scene after done is 409", afterDoneStatus == 409)

  Node.HttpServer.close(server6, () => ())
  Store.close(store6)
}
