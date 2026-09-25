// Claude timeout: point the brain at a local stub that never answers, with a
// 300 ms timeout. POST /api/scene must answer 504 with a JSON error, not the
// generic 500. The stub is on 127.0.0.1, so no real Claude call is billed.

let run = async () => {
  TestKit.section("Server: Claude timeout answers 504 JSON")

  let stub = Node.HttpServer.createServer((_req, _res) => ())
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
    claudeUrl: "http://127.0.0.1:" ++ Int.toString(stubPort) ++ "/v1/messages",
    claudeTimeoutMs: 300,
  }

  let {Server.server: server, port} = await Server.start(config)

  let resp = await Fetch.fetch(
    "http://127.0.0.1:" ++ Int.toString(port) ++ "/api/scene",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "image/jpeg")]),
      body: "stub-mode-ignores-this-body",
      signal: Fetch.AbortSignal.timeout(10_000),
    },
  )
  TestKit.check("POST /api/scene responds 504", Fetch.status(resp) == 504)
  let json = await Fetch.json(resp)
  TestKit.check(
    "504 reply names the timeout",
    Json.stringField(json, "error") == Some("Claude took longer than 0.3 s"),
  )
  TestKit.check(
    "a timed-out scene is not logged",
    !Node.Fs.existsSync(Node.Path.join([dataDir, "scenes.jsonl"])),
  )

  Node.HttpServer.close(server, () => ())
  Node.HttpServer.close(stub, () => ())
}
