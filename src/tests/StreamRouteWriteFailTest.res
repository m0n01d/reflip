// StreamRoute.handle when a data file write throws (review finding R3):
// writeRawEvents or SceneLog.appendLine, for example on a full disk or a
// bad data directory. The last-resort catch around the priced pass must
// still end the scene: `error` ("scene failed: ..."), then `end` with
// status `failed`, as the last event. Without it, the scene stayed
// Running with no `end`, and a page that reconnects waited forever.
//
// The data directory here sits under a regular file, so the first
// mkdirSync in SceneLog.ensureDirs throws ENOTDIR. The stream route is
// the only code that writes there (the helper server skips Server.start,
// which opens its SQLite store in the data directory).

let cwd = Node.Process.cwd()

let badDataDir = (): string => {
  let file = Node.Path.join([Node.Os.tmpdir(), "reflip-test-" ++ Node.Crypto.randomUUID()])
  Node.Fs.writeFileSync(file, "a file, not a directory")
  Node.Path.join([file, "data"])
}

let configFor = (~fixturesDir: string): Config.t => {
  Config.port: 0,
  fixtures: true,
  dataDir: badDataDir(),
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

let runCase = async (~title: string, ~fixturesDir: string) => {
  TestKit.section(title)
  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "3")
  let (server, port) = await StreamRouteEbayFailTest.startRoute(
    ~buildSceneReply=Server.buildSceneReply,
    configFor(~fixturesDir),
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
    "the error says the scene failed, with the write error",
    sceneEvents[n - 2]
    ->Option.flatMap(StreamRouteEbayFailTest.parseData)
    ->Option.flatMap(j => Json.stringField(j, "message"))
    ->Option.map(m => String.startsWith(m, "scene failed: ") && String.includes(m, "ENOTDIR"))
    ->Option.getOr(false),
  )
  TestKit.check(
    "end status is failed",
    sceneEvents[n - 1]
    ->Option.flatMap(StreamRouteEbayFailTest.parseData)
    ->Option.flatMap(j => Json.stringField(j, "status")) == Some("failed"),
  )
  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "")
  Node.HttpServer.close(server, () => ())
}

let run = async () => {
  // Completed branch: writeRawEvents throws before the eBay merge.
  await runCase(
    ~title="StreamRoute: a raw events write that throws still ends the scene",
    ~fixturesDir=Node.Path.join([cwd, "tests/fixtures"]),
  )
  // Cut-off branch: its own writeRawEvents throws before its log line.
  await runCase(
    ~title="StreamRoute: a write that throws on a cut-off reply still ends the scene",
    ~fixturesDir=Node.Path.join([cwd, "tests/fixtures/cutoff"]),
  )
}
