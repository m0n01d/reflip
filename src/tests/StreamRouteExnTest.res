// Proves the fix to StreamRoute.res's last-resort catch (the `try` around
// the ClaudeStream.run call): it now matches any exception, not only a JS
// Error wrapped as JsExn. The seam is STREAM_THROW_EXN, a fixture-mode-only
// test switch declared next to STREAM_DROP_AFTER_MS in StreamRoute.res --
// it raises StreamRouteTestThrow, a plain ReScript `exception`, with
// `raise`, before the Claude call. No JS Error, no fs call, no dataDir
// trick: unlike StreamRouteWriteFailTest.res's ENOTDIR, this failure never
// touches JS-land at all.

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

let run = async () => {
  TestKit.section("StreamRoute: a plain ReScript exception (not a JS Error) still ends the scene")
  Dict.set(Node.Process.env, "STREAM_THROW_EXN", "1")
  let (server, port) = await StreamRouteEbayFailTest.startRoute(
    ~buildSceneReply=Server.buildSceneReply,
    config,
  )
  let resp = await StreamRouteEbayFailTest.postPhoto(port)
  TestKit.check("POST /api/scene/stream responds 200", Fetch.status(resp) == 200)
  let events = await StreamRouteEbayFailTest.readAllEvents(resp, ~onEvent=_ => ())
  let kinds = Array.map(events, e => e.event)
  let sceneEvents = Array.filter(events, e => !String.startsWith(e.event, "spot-"))
  let n = Array.length(sceneEvents)
  TestKit.check(
    "the scene ends in error, end (spot events aside) -- got " ++ Array.join(kinds, ","),
    n >= 2 &&
    sceneEvents[n - 2]->Option.map(e => e.event) == Some("error") &&
    sceneEvents[n - 1]->Option.map(e => e.event) == Some("end"),
  )
  TestKit.check(
    "end is the last event, and there is exactly one",
    kinds[Array.length(kinds) - 1] == Some("end") &&
      Array.filter(kinds, k => k == "end")->Array.length == 1,
  )
  TestKit.check(
    "the error says the scene failed, with unknown error standing in for a plain exception",
    sceneEvents[n - 2]
    ->Option.flatMap(StreamRouteEbayFailTest.parseData)
    ->Option.flatMap(j => Json.stringField(j, "message")) == Some("scene failed: unknown error"),
  )
  TestKit.check(
    "end status is failed",
    sceneEvents[n - 1]
    ->Option.flatMap(StreamRouteEbayFailTest.parseData)
    ->Option.flatMap(j => Json.stringField(j, "status")) == Some("failed"),
  )
  Dict.set(Node.Process.env, "STREAM_THROW_EXN", "")
  Node.HttpServer.close(server, () => ())
}
