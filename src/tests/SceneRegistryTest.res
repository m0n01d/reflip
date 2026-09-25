// Tests SceneRegistry end to end, through the routes in Server.res:
// replay, an attach mid-run, a POST close, stop, expiry, and the
// fixture-mode drop switch. One local server in fixture mode, the same
// way StreamRouteTest.res tests POST /api/scene/stream.

let cwd = Node.Process.cwd()

// The fixture SSE's event kinds in order, wrapped with StreamRoute's own
// photo-received, scene and end. Matches StreamRouteTest.res's own
// expectedKinds; kept as a separate copy so this file does not depend on
// another test file's internals.
let expectedKinds = [
  "photo-received",
  "claude-started",
  "thinking",
  "tool-run",
  "search-started",
  "search-done",
  "tool-done",
  "search-started",
  "search-failed",
  "item",
  "item",
  "item",
  "done",
  "scene",
  // No tests/fixtures/claude-spot fixture exists, so the spot pass ends in
  // SpotPass.NoFixture and StreamRoute.handle's finishSpot writes exactly
  // this one event, right before `end`.
  "spot-failed",
  "end",
]

let baseConfig = (dataDir: string): Config.t => {
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

// Drains a response body as SSE to the end of the stream. Same
// reader/TextDecoder/Sse.feed loop as StreamRouteTest.res's readAllEvents.
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

// Reads only up to the first `photo-received` event and returns its
// sceneId, then stops. Used to learn a scene's id while it is still
// running, without waiting for the rest of the fixture to play out.
let firstSceneId = async (resp: Fetch.response): string => {
  let idRef = ref("")
  switch Fetch.body(resp) {
  | None => ()
  | Some(stream) => {
      let reader = Fetch.getReader(stream)
      let decoder = TextDecoder.make()
      let sseStateRef = ref(Sse.empty)
      let rec readLoop = async (): unit =>
        if idRef.contents != "" {
          ()
        } else {
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
                switch Array.find(events, e => e.event == "photo-received") {
                | Some(e) =>
                  switch JsonCombinators.Json.parse(e.data) {
                  | Ok(json) => idRef := Json.stringField(json, "sceneId")->Option.getOr("")
                  | Error(_) => ()
                  }
                | None => ()
                }
                await readLoop()
              }
            }
          }
        }
      await readLoop()
    }
  }
  idRef.contents
}

let sceneIdOf = (events: array<Sse.event>): string =>
  Array.find(events, e => e.event == "photo-received")
  ->Option.flatMap(e =>
    switch JsonCombinators.Json.parse(e.data) {
    | Ok(json) => Json.stringField(json, "sceneId")
    | Error(_) => None
    }
  )
  ->Option.getOr("")

let kindsOf = (events: array<Sse.event>): array<string> => Array.map(events, e => e.event)

let postScene = (port: int, photo: Node.Buffer.t): promise<Fetch.response> =>
  Fetch.fetchBuffer(
    "http://127.0.0.1:" ++ Int.toString(port) ++ "/api/scene/stream",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "image/jpeg")]),
      body: photo,
      signal: Fetch.AbortSignal.timeout(20_000),
    },
  )

let postSceneWithSignal = (
  port: int,
  photo: Node.Buffer.t,
  signal: Fetch.AbortSignal.t,
): promise<Fetch.response> =>
  Fetch.fetchBuffer(
    "http://127.0.0.1:" ++ Int.toString(port) ++ "/api/scene/stream",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "image/jpeg")]),
      body: photo,
      signal,
    },
  )

let getEvents = (port: int, sceneId: string, ~from: option<int>): promise<Fetch.response> => {
  let query = switch from {
  | None => ""
  | Some(n) => "?from=" ++ Int.toString(n)
  }
  Fetch.fetch(
    "http://127.0.0.1:" ++ Int.toString(port) ++ "/api/scene/" ++ sceneId ++ "/events" ++ query,
    ~init={Fetch.method: "GET", signal: Fetch.AbortSignal.timeout(20_000)},
  )
}

let postStop = (port: int, sceneId: string): promise<Fetch.response> =>
  Fetch.fetch(
    "http://127.0.0.1:" ++ Int.toString(port) ++ "/api/scene/" ++ sceneId ++ "/stop",
    ~init={Fetch.method: "POST", signal: Fetch.AbortSignal.timeout(20_000)},
  )

// Replay from 0 (default) and from n both match what the original POST
// connection saw, once the scene has ended.
let testReplay = async (port: int, photo: Node.Buffer.t) => {
  TestKit.section("SceneRegistry: replay from 0 and from n")
  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "5")
  let resp = await postScene(port, photo)
  let full = await readEvents(resp)
  let sceneId = sceneIdOf(full)
  TestKit.check("captured a sceneId", sceneId != "")
  TestKit.check(
    "the POST stream ends in `end`",
    Array.get(full, Array.length(full) - 1)->Option.map(e => e.event) == Some("end"),
  )

  let replay0Resp = await getEvents(port, sceneId, ~from=None)
  let replay0 = await readEvents(replay0Resp)
  TestKit.check(
    "GET .../events (default from=0) replays the full buffer",
    Array.join(kindsOf(replay0), ",") == Array.join(kindsOf(full), ","),
  )

  let n = Array.length(full) / 2
  let replayNResp = await getEvents(port, sceneId, ~from=Some(n))
  let replayN = await readEvents(replayNResp)
  let expectedTail = Array.slice(full, ~start=n, ~end=Array.length(full))
  TestKit.check(
    "GET .../events?from=n replays only the tail",
    Array.join(kindsOf(replayN), ",") == Array.join(kindsOf(expectedTail), ","),
  )
}

// A GET attach part way through a run first replays the buffer so far,
// then keeps receiving live events until `end` — the same full sequence
// the original POST connection sees.
let testAttachMidRun = async (port: int, photo: Node.Buffer.t) => {
  TestKit.section("SceneRegistry: attach in the middle of a run")
  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "150")
  let resp = await postScene(port, photo)
  let sceneId = await firstSceneId(resp)
  TestKit.check("captured a sceneId while the scene is still running", sceneId != "")

  let attachResp = await getEvents(port, sceneId, ~from=None)
  TestKit.check("the mid-run GET responds 200", Fetch.status(attachResp) == 200)
  let events = await readEvents(attachResp)
  TestKit.check(
    "the mid-run GET sees the full event sequence, replay plus live",
    Array.join(kindsOf(events), ",") == Array.join(expectedKinds, ","),
  )
}

// Closing the POST connection detaches it as a listener only. The scene
// itself keeps running, and a GET reconnect reads it through to `end`.
let testPostCloseKeepsRunning = async (port: int, photo: Node.Buffer.t) => {
  TestKit.section("SceneRegistry: a POST close leaves the scene running to `end`")
  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "100")
  let clientController = Fetch.AbortController.make()
  let resp = await postSceneWithSignal(port, photo, Fetch.AbortController.signal(clientController))
  let sceneId = await firstSceneId(resp)
  TestKit.check("captured a sceneId before closing the POST", sceneId != "")

  Fetch.AbortController.abort(clientController)
  await ClaudeStream.sleep(50)

  let checkResp = await getEvents(port, sceneId, ~from=None)
  TestKit.check("the scene is still known right after the close", Fetch.status(checkResp) == 200)
  let events = await readEvents(checkResp)
  TestKit.check(
    "the scene reaches `end` after its POST connection closed",
    Array.get(events, Array.length(events) - 1)->Option.map(e => e.event) == Some("end"),
  )
}

// POST /api/scene/:id/stop: 404 for an unknown id, 202 while running, 200
// once the scene has ended (including the ended-by-stop case).
let testStopCodes = async (port: int, photo: Node.Buffer.t) => {
  TestKit.section("SceneRegistry: stop is 202 running, 404 unknown, 200 ended")

  let notFoundResp = await postStop(port, "no-such-scene-id")
  TestKit.check("stop on an unknown id is 404", Fetch.status(notFoundResp) == 404)

  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "150")
  let resp = await postScene(port, photo)
  let sceneId = await firstSceneId(resp)
  TestKit.check("captured a sceneId for the stop test", sceneId != "")

  let stopResp = await postStop(port, sceneId)
  TestKit.check("stop on a running scene is 202", Fetch.status(stopResp) == 202)
  let stopJson = await Fetch.json(stopResp)
  TestKit.check(
    "the 202 body reports stopping",
    Json.stringField(stopJson, "status") == Some("stopping"),
  )

  // The abort from the stop above unwinds the fixture run; read the scene
  // through GET events so it is Ended before the next check.
  let drainResp = await getEvents(port, sceneId, ~from=None)
  let _ = await readEvents(drainResp)

  let endedResp = await postStop(port, sceneId)
  TestKit.check("stop on an ended scene is 200", Fetch.status(endedResp) == 200)
  let endedJson = await Fetch.json(endedResp)
  TestKit.check(
    "the 200 body reports the end status",
    Json.stringField(endedJson, "status") == Some("stopped"),
  )
}

// A scene that ended more than SCENE_KEEP_MS ago is swept away the next
// time a scene starts, and its id then 404s.
let testExpiry = async (port: int, photo: Node.Buffer.t) => {
  TestKit.section("SceneRegistry: an expired scene is swept when a new scene starts")
  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "5")
  let resp = await postScene(port, photo)
  let full = await readEvents(resp)
  let sceneId = sceneIdOf(full)
  TestKit.check("captured a sceneId to expire", sceneId != "")

  Dict.set(Node.Process.env, "SCENE_KEEP_MS", "20")
  await ClaudeStream.sleep(60)
  let _ = await postScene(port, photo)
  Dict.set(Node.Process.env, "SCENE_KEEP_MS", "")

  let checkResp = await getEvents(port, sceneId, ~from=None)
  TestKit.check("an expired scene's id now 404s", Fetch.status(checkResp) == 404)
}

// STREAM_DROP_AFTER_MS (fixture mode only) destroys the POST socket
// partway through, but the scene keeps running and still reaches `end`.
let testDropSwitch = async (port: int, photo: Node.Buffer.t) => {
  TestKit.section("SceneRegistry: STREAM_DROP_AFTER_MS drops the socket, the scene keeps running")
  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "150")
  Dict.set(Node.Process.env, "STREAM_DROP_AFTER_MS", "80")
  let resp = await postScene(port, photo)
  let sceneId = await firstSceneId(resp)
  Dict.set(Node.Process.env, "STREAM_DROP_AFTER_MS", "")
  TestKit.check("captured a sceneId before the socket drop", sceneId != "")

  let checkResp = await getEvents(port, sceneId, ~from=None)
  TestKit.check("the scene is still known after the socket drop", Fetch.status(checkResp) == 200)
  let events = await readEvents(checkResp)
  TestKit.check(
    "the scene reaches `end` after its POST socket was destroyed",
    Array.get(events, Array.length(events) - 1)->Option.map(e => e.event) == Some("end"),
  )
}

let run = async () => {
  let dataDir = Node.Path.join([Node.Os.tmpdir(), "reflip-test-" ++ Node.Crypto.randomUUID()])
  let config = baseConfig(dataDir)
  let {Server.server: server, port} = await Server.start(config)
  let photo = Node.Fs.readFileBuffer(Node.Path.join([cwd, "tests/fixtures/table.jpg"]))

  await testReplay(port, photo)
  await testAttachMidRun(port, photo)
  await testPostCloseKeepsRunning(port, photo)
  await testStopCodes(port, photo)
  await testExpiry(port, photo)
  await testDropSwitch(port, photo)

  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "")
  Node.HttpServer.close(server, () => ())
}
