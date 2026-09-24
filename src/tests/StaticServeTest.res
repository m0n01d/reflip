// Static serving: dist/manifest.webmanifest (built by `npm run build`
// before tests run, since `npm test` runs the build first) comes back 200
// with its content type. A path that tries to leave dist/ comes back 404
// either way — whether the traversal check catches it, or the file simply
// does not exist in dist/, per the brief's own curl verification.

let run = async () => {
  TestKit.section("Server: static files under dist/")

  let cwd = Node.Process.cwd()
  let config: Config.t = {
    Config.port: 0,
    fixtures: true,
    dataDir: Node.Path.join([Node.Os.tmpdir(), "reflip-test-" ++ Node.Crypto.randomUUID()]),
    fixturesDir: Node.Path.join([cwd, "tests/fixtures"]),
    anthropicApiKey: None,
    ebayClientId: None,
    ebayClientSecret: None,
    structuredOutput: true,
    distIndexPath: Node.Path.join([cwd, "dist/index.html"]),
    distDir: Node.Path.join([cwd, "dist"]),
  }

  let {Server.server, port} = await Server.start(config)
  let base = "http://127.0.0.1:" ++ Int.toString(port)

  let manifestResp = await Fetch.fetch(base ++ "/manifest.webmanifest")
  TestKit.check("a known dist file returns 200", Fetch.status(manifestResp) == 200)
  let contentType =
    Fetch.getHeader(Fetch.responseHeaders(manifestResp), "content-type")->Nullable.toOption
  TestKit.check(
    "a known dist file has the right content type",
    contentType == Some("application/manifest+json"),
  )

  let traversalResp = await Fetch.fetch(base ++ "/../package.json")
  TestKit.check("a path that leaves dist/ returns 404", Fetch.status(traversalResp) == 404)

  Node.HttpServer.close(server, () => ())
}
