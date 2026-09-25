// Server: start on a free port with FIXTURES=1, POST a scene, check the
// reply shape and the new line in the log.

let run = async () => {
  TestKit.section("Server: fixture-mode POST /api/scene")

  let cwd = Node.Process.cwd()
  let dataDir = Node.Path.join([Node.Os.tmpdir(), "reflip-test-" ++ Node.Crypto.randomUUID()])
  let config: Config.t = {
    Config.port: 0,
    fixtures: true,
    dataDir,
    fixturesDir: Node.Path.join([cwd, "tests/fixtures"]),
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

  let {Server.server: server, port} = await Server.start(config)

  // Fixture mode never reads the request body for the Claude call — it
  // always loads tests/fixtures/claude-scene.json instead — but the size
  // now comes off the real bytes (JpegSize.res), so this POSTs the real
  // fixture photo. The brief's own curl verification does the same against
  // a live `npm start`.
  let photo = Node.Fs.readFileBuffer(Node.Path.join([cwd, "tests/fixtures/table.jpg"]))
  let resp = await Fetch.fetchBuffer(
    "http://127.0.0.1:" ++ Int.toString(port) ++ "/api/scene",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "image/jpeg")]),
      body: photo,
    },
  )
  TestKit.check("POST /api/scene responds 200", Fetch.status(resp) == 200)
  let json = await Fetch.json(resp)
  TestKit.check("reply has a sceneId", Json.stringField(json, "sceneId")->Option.isSome)
  TestKit.check("reply is marked fixture=true", Json.boolField(json, "fixture") == Some(true))
  TestKit.check(
    "reply's imageWidth/imageHeight match the real fixture photo (64x48)",
    Json.intField(json, "imageWidth") == Some(64) && Json.intField(json, "imageHeight") == Some(48),
  )
  let items = Json.arrayField(json, "items")->Option.getOr([])
  TestKit.check("reply has 3 items (fixture)", Array.length(items) == 3)
  TestKit.check(
    "each fixture item decodes a box that holds it inside the 64x48 photo",
    Array.every(items, item =>
      switch Json.field(item, "box")->Option.flatMap(Shared.decodeBox) {
      | Some(b) => b.x1 >= 0 && (b.y1 >= 0 && (b.x2 <= 64 && b.y2 <= 48))
      | None => false
      }
    ),
  )

  let logPath = Node.Path.join([dataDir, "scenes.jsonl"])
  TestKit.check("scenes.jsonl was written", Node.Fs.existsSync(logPath))
  let logText = Node.Fs.readFileUtf8(logPath, "utf8")
  TestKit.check("scenes.jsonl has a line", String.length(String.trim(logText)) > 0)

  let badResp = await Fetch.fetch(
    "http://127.0.0.1:" ++ Int.toString(port) ++ "/api/scene?model=gpt-4",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "image/jpeg")]),
      body: "fixture-mode-ignores-this-body",
    },
  )
  TestKit.check("POST /api/scene?model=gpt-4 responds 400", Fetch.status(badResp) == 400)
  let badJson = await Fetch.json(badResp)
  TestKit.check("400 reply has an error field", Json.stringField(badJson, "error")->Option.isSome)
  let validModels = Json.arrayField(badJson, "validModels")->Option.getOr([])
  TestKit.check("400 reply lists 3 valid model ids", Array.length(validModels) == 3)

  Node.HttpServer.close(server, () => ())
}
