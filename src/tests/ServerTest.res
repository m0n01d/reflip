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
  }

  let {Server.server, port} = await Server.start(config)

  // Fixture mode never reads the request body — it always loads
  // tests/fixtures/claude-scene.json instead — so a placeholder body is
  // enough here. The brief's own curl verification POSTs the real
  // tests/fixtures/table.jpg against a live `npm start`.
  let resp = await Fetch.fetch(
    "http://127.0.0.1:" ++ Int.toString(port) ++ "/api/scene",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "image/jpeg")]),
      body: "fixture-mode-ignores-this-body",
    },
  )
  TestKit.check("POST /api/scene responds 200", Fetch.status(resp) == 200)
  let json = await Fetch.json(resp)
  TestKit.check("reply has a sceneId", Json.stringField(json, "sceneId")->Option.isSome)
  TestKit.check("reply is marked fixture=true", Json.boolField(json, "fixture") == Some(true))
  let items = Json.arrayField(json, "items")->Option.getOr([])
  TestKit.check("reply has 3 items (fixture)", Array.length(items) == 3)

  let logPath = Node.Path.join([dataDir, "scenes.jsonl"])
  TestKit.check("scenes.jsonl was written", Node.Fs.existsSync(logPath))
  let logText = Node.Fs.readFileUtf8(logPath, "utf8")
  TestKit.check("scenes.jsonl has a line", String.length(String.trim(logText)) > 0)

  Node.HttpServer.close(server, () => ())
}
