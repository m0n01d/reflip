// StreamRoute.handle: a rejected Claude fetch (not a timeout, not a client
// abort -- ClaudeStream.runLive's own catch only handles those two) must
// still end the scene cleanly, `error` then `end` with status `failed`,
// instead of leaving the promise chain uncaught with no `end` event ever
// sent. Opus review of 60920ed, brief item 1 (High). Also proves the
// server keeps serving afterward, by repeating the same request.

let cwd = Node.Process.cwd()

let readEvents = async (resp: Fetch.response): array<Sse.event> => {
  let received: array<Sse.event> = []
  switch Fetch.body(resp) {
  | None => ()
  | Some(stream) => {
      let reader = Fetch.getReader(stream)
      let decoder = TextDecoder.make()
      let sseStateRef = ref(Sse.empty)
      let rec readLoop = async (): unit => {
        let chunk = await Fetch.read(reader)
        if chunk.done {
          ()
        } else {
          switch chunk.value {
          | None => await readLoop()
          | Some(bytes) => {
              let text = TextDecoder.decodeStream(decoder, bytes, {stream: true})
              let (state2, events) = Sse.feed(sseStateRef.contents, text)
              sseStateRef := state2
              Array.forEach(events, e => Array.push(received, e)->ignore)
              await readLoop()
            }
          }
        }
      }
      await readLoop()
    }
  }
  received
}

// A real ephemeral port that had a listener a moment ago and does not by
// the time the test connects to it: a fast, OS-level ECONNREFUSED for the
// Claude fetch inside ClaudeStream.runLive, with no live network call.
let deadPort = async (): int => {
  let srv = Node.HttpServer.createServer((_req, _res) => ())
  let port = await Promise.make((resolve, _reject) =>
    Node.HttpServer.listen(srv, 0, "127.0.0.1", () => resolve(Node.HttpServer.address(srv).port))
  )
  await Promise.make((resolve, _reject) => Node.HttpServer.close(srv, () => resolve()))
  port
}

let run = async () => {
  TestKit.section(
    "StreamRoute: a rejected Claude fetch still ends the scene, and the server keeps serving",
  )

  let claudePort = await deadPort()
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
    claudeUrl: "http://127.0.0.1:" ++ Int.toString(claudePort) ++ "/v1/messages",
  }

  let {Server.server: server, port} = await Server.start(config)
  let photo = Node.Fs.readFileBuffer(Node.Path.join([cwd, "tests/fixtures/table.jpg"]))

  let postOnce = async () => {
    let resp = await Fetch.fetchBuffer(
      "http://127.0.0.1:" ++ Int.toString(port) ++ "/api/scene/stream",
      ~init={
        Fetch.method: "POST",
        headers: Dict.fromArray([("content-type", "image/jpeg")]),
        body: photo,
        signal: Fetch.AbortSignal.timeout(15_000),
      },
    )
    TestKit.check("POST /api/scene/stream still responds 200", Fetch.status(resp) == 200)
    let events = await readEvents(resp)
    let kinds = Array.map(events, e => e.event)
    let n = Array.length(kinds)
    // The spot pass calls the same dead URL, so finishSpot reports its own
    // spot-failed before `end`. Only spot events can come between the
    // scene's `error` and its `end`, and `end` is always the last event.
    let sceneKinds = Array.filter(kinds, k => !String.startsWith(k, "spot-"))
    let m = Array.length(sceneKinds)
    TestKit.check(
      "the stream ends in error, end (spot events aside) -- got " ++ Array.join(kinds, ","),
      m >= 2 &&
      Array.get(sceneKinds, m - 2) == Some("error") &&
      Array.get(sceneKinds, m - 1) == Some("end") &&
      Array.get(kinds, n - 1) == Some("end"),
    )
    switch Array.get(events, Array.length(events) - 1) {
    | None => TestKit.check("an end event was received", false)
    | Some(endEvt) =>
      switch JsonCombinators.Json.parse(endEvt.data) {
      | Error(_) => TestKit.check("end event data parses as JSON", false)
      | Ok(json) =>
        TestKit.check(
          "end event status is failed",
          Json.stringField(json, "status") == Some("failed"),
        )
      }
    }
  }

  await postOnce()
  // Nothing about a second connection could be trusted before this fix --
  // the first scene never sent `end`, and the unhandled rejection reached
  // Server.res's top-level catch. Repeat the same request to show the
  // first failure did not wedge or crash the server.
  await postOnce()

  Node.HttpServer.close(server, () => ())
}
