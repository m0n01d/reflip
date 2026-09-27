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
    haulConcurrency: 4,
    haulMaxUsd: 10.0,
    haulGemMinUsd: 20.0,
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
  TestKit.check(
    "a non-hashed dist file (not under /assets/) is never cached — a stale manifest after a deploy would be wrong with no way to detect it",
    Fetch.getHeader(Fetch.responseHeaders(manifestResp), "cache-control")->Nullable.toOption ==
      Some("no-store"),
  )

  let traversalResp = await Fetch.fetch(base ++ "/../package.json")
  TestKit.check("a path that leaves dist/ returns 404", Fetch.status(traversalResp) == 404)

  // index.html is the one file that decides which hashed bundle loads —
  // it must never be cached, or a reload can keep pointing at a bundle
  // that no longer exists on the next deploy (docs/spec-upload-progress.md
  // follow-up: cache busting + a visible build version).
  TestKit.section("Server: cache-control")

  let rootResp = await Fetch.fetch(base ++ "/")
  TestKit.check(
    "GET / (index.html) is never cached",
    Fetch.getHeader(Fetch.responseHeaders(rootResp), "cache-control")->Nullable.toOption ==
      Some("no-store"),
  )

  TestKit.section("Server: GET /api/version")

  let versionResp = await Fetch.fetch(base ++ "/api/version")
  TestKit.check("GET /api/version is 200", Fetch.status(versionResp) == 200)
  let versionJson = await Fetch.json(versionResp)
  TestKit.check(
    "the reply names the running commit",
    Json.stringField(versionJson, "commitSha") == Some(BuildInfo.commitSha),
  )
  TestKit.check(
    "the reply says whether this build has uncommitted changes",
    Json.boolField(versionJson, "dirty") == Some(BuildInfo.dirty),
  )
  TestKit.check(
    "the reply names when this build ran",
    Json.stringField(versionJson, "builtAt") == Some(BuildInfo.builtAt),
  )

  // GET /api/scenes/:id/photo (docs/spec-haul-mode.md "The routes"): the id
  // gets the same 1-to-64-of-[A-Za-z0-9-] check as a client id, and the
  // resolved path is guarded the same way dist/ is guarded above.
  TestKit.section("Server: GET /api/scenes/:id/photo")

  let badIdResp = await Fetch.fetch(base ++ "/api/scenes/..%2F../photo")
  TestKit.check("a scene id outside [A-Za-z0-9-] is 400", Fetch.status(badIdResp) == 400)

  let unknownIdResp = await Fetch.fetch(base ++ "/api/scenes/no-such-scene/photo")
  TestKit.check("an unknown scene id is 404", Fetch.status(unknownIdResp) == 404)
  let unknownIdJson = await Fetch.json(unknownIdResp)
  TestKit.check(
    "the 404 reply has an error field, same shape as the 400",
    Json.stringField(unknownIdJson, "error")->Option.isSome,
  )

  Node.HttpServer.close(server, () => ())
}
