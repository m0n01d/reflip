// Claude cut-off (stop_reason "max_tokens"): point the brain at a local stub
// that answers 200 with a truncated reply. POST /api/scene must still answer
// 502 with a JSON error, but now it also has to log what got billed — the
// usage, the cost and the raw response — since a max_tokens reply is real
// spend with no decoded items to show for it. The stub is on 127.0.0.1, so
// no real Claude call is billed.

let run = async () => {
  TestKit.section("Server: Claude cut-off (max_tokens) logs and answers 502")

  let stubBody = Json.obj([
    ("stop_reason", Json.str("max_tokens")),
    (
      "content",
      Json.arr([
        Json.obj([
          ("type", Json.str("text")),
          ("text", Json.str("{\"items\": [{\"name\": \"lamp\"")),
        ]),
      ]),
    ),
    (
      "usage",
      Json.obj([
        ("input_tokens", Json.num(3000.0)),
        ("output_tokens", Json.num(8192.0)),
        ("server_tool_use", Json.obj([("web_search_requests", Json.num(2.0))])),
      ]),
    ),
  ])

  let stub = Node.HttpServer.createServer((_req, res) => {
    Node.HttpServer.writeHead(res, 200, Dict.fromArray([("Content-Type", "application/json")]))
    Node.HttpServer.endWithBody(res, JSON.stringify(stubBody))
  })
  let stubPort = await Promise.make((resolve, _reject) =>
    Node.HttpServer.listen(stub, 0, "127.0.0.1", () => resolve(Node.HttpServer.address(stub).port))
  )

  let cwd = Node.Process.cwd()
  let dataDir = Node.Path.join([Node.Os.tmpdir(), "reflip-test-" ++ Node.Crypto.randomUUID()])
  let config: Config.t = {
    Config.port: 0,
    fixtures: false,
    dataDir,
    fixturesDir: Node.Path.join([cwd, "tests/fixtures"]),
    anthropicApiKey: Some("test-key-not-real"),
    ebayClientId: None,
    ebayClientSecret: None,
    structuredOutput: true,
    distIndexPath: Node.Path.join([cwd, "dist/index.html"]),
    distDir: Node.Path.join([cwd, "dist"]),
    haulConcurrency: 4,
    haulMaxUsd: 10.0,
    haulGemMinUsd: 20.0,
    claudeUrl: "http://127.0.0.1:" ++ Int.toString(stubPort) ++ "/v1/messages",
  }

  let {Server.server: server, port} = await Server.start(config)

  let photo = Node.Fs.readFileBuffer(Node.Path.join([cwd, "tests/fixtures/table.jpg"]))
  let resp = await Fetch.fetchBuffer(
    "http://127.0.0.1:" ++ Int.toString(port) ++ "/api/scene",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "image/jpeg")]),
      body: photo,
      signal: Fetch.AbortSignal.timeout(10_000),
    },
  )
  TestKit.check("POST /api/scene responds 502", Fetch.status(resp) == 502)
  let json = await Fetch.json(resp)
  TestKit.check("502 reply names the cut-off", Json.stringField(json, "error") == Some("reply cut off"))
  let sceneId = Json.stringField(json, "sceneId")
  TestKit.check("502 reply has a sceneId", sceneId->Option.isSome)

  let sceneIdStr = sceneId->Option.getOr("")
  let rawPath = Node.Path.join([dataDir, "raw", sceneIdStr ++ ".json"])
  TestKit.check("data/raw/<sceneId>.json exists", Node.Fs.existsSync(rawPath))
  let rawJson = JSON.parseOrThrow(Node.Fs.readFileUtf8(rawPath, "utf8"))
  TestKit.check(
    "the raw dump's stop_reason is max_tokens",
    Json.stringField(rawJson, "stop_reason") == Some("max_tokens"),
  )

  let logPath = Node.Path.join([dataDir, "scenes.jsonl"])
  let logText = Node.Fs.readFileUtf8(logPath, "utf8")
  let logLines = String.split(String.trim(logText), "\n")
  TestKit.check("scenes.jsonl has exactly one line", Array.length(logLines) == 1)
  let logLine = JSON.parseOrThrow(Array.getUnsafe(logLines, 0))
  TestKit.check(
    "the log line names the cut-off error",
    Json.stringField(logLine, "error") == Some("reply cut off"),
  )
  TestKit.check(
    "the log line has the same sceneId as the reply",
    Json.stringField(logLine, "sceneId") == sceneId,
  )
  let cost = Json.field(logLine, "cost")
  TestKit.check(
    "the log line's cost.outputTokens is 8192",
    cost->Option.flatMap(c => Json.intField(c, "outputTokens")) == Some(8192),
  )
  TestKit.check(
    "the log line's cost.webSearches is 2",
    cost->Option.flatMap(c => Json.intField(c, "webSearches")) == Some(2),
  )
  TestKit.check(
    "the log line's cost.usd is positive",
    cost->Option.flatMap(c => Json.floatField(c, "usd"))->Option.getOr(0.0) > 0.0,
  )

  Node.HttpServer.close(server, () => ())
  Node.HttpServer.close(stub, () => ())

  // The fix for the cut-off: room for adaptive thinking, and a cap on the
  // number of items the scene prompt asks for.
  let body = ClaudeClient.buildRequestBody(
    ~model=Shared.modelId(Shared.defaultModel),
    ~imageBase64="",
    ~structuredOutput=true,
    ~mode=ClaudeClient.Scene({width: 1800, height: 1039}),
  )
  TestKit.check(
    "the request asks for max_tokens 16000",
    Json.intField(body, "max_tokens") == Some(16_000),
  )
  TestKit.check(
    "the scene prompt caps the list at 30 items",
    String.includes(Json.stringField(body, "system")->Option.getOr(""), "List at most 30 items."),
  )
}
