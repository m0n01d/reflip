// POST /api/scene/stream: the fixture-mode happy path (event order, that
// items really do arrive before the stream ends, and the final `scene`
// event decodes), then the early-stop path (the client aborts after the
// first item; the upstream request to Claude must abort too, and the
// scene log must still get a line for what was found so far).

let cwd = Node.Process.cwd()

// Every SceneStream.logEvent the fixture SSE actually produces, in order,
// via StreamRoute's SSE names — see SceneStreamTest.res's own
// `expectedKinds` for the SceneStream-level list this maps from. Wrapped
// with StreamRoute's own photo-received and scene.
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
]

// Reads a fetch response body as SSE, one event at a time, with its
// arrival time relative to `t0`. Same reader/TextDecoder/Sse.feed loop
// ClaudeStream.runLive itself uses against the real network.
let readAllEvents = async (resp: Fetch.response, t0: float): array<(float, Sse.event)> => {
  let received: array<(float, Sse.event)> = []
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
              let now = Date.now() -. t0
              Array.forEach(events, e => Array.push(received, (now, e))->ignore)
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

let runHappyPath = async () => {
  TestKit.section("StreamRoute: fixture-mode POST /api/scene/stream")

  // ClaudeStream.fixtureDelayMs reads this straight off process.env (it is
  // not part of Config.t), so it has to be a real env var, not a config
  // field. Restored to "" (== unset, per Config.getEnv) when done.
  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "30")

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

  let photo = Node.Fs.readFileBuffer(Node.Path.join([cwd, "tests/fixtures/table.jpg"]))
  let t0 = Date.now()
  let resp = await Fetch.fetchBuffer(
    "http://127.0.0.1:" ++ Int.toString(port) ++ "/api/scene/stream",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "image/jpeg")]),
      body: photo,
      signal: Fetch.AbortSignal.timeout(15_000),
    },
  )
  TestKit.check("POST /api/scene/stream responds 200", Fetch.status(resp) == 200)
  TestKit.check(
    "content-type is text/event-stream",
    Fetch.getHeader(Fetch.responseHeaders(resp), "content-type")
    ->Nullable.toOption
    ->Option.map(s => String.includes(s, "text/event-stream"))
    ->Option.getOr(false),
  )

  let received = await readAllEvents(resp, t0)
  let kinds = Array.map(received, ((_, e)) => e.event)
  TestKit.check(
    "event kind count matches the fixture's shape",
    Array.length(kinds) == Array.length(expectedKinds),
  )
  TestKit.check(
    "event kinds come in order",
    Array.join(kinds, ",") == Array.join(expectedKinds, ","),
  )

  switch (Array.find(received, ((_, e)) => e.event == "item"), Array.get(received, Array.length(received) - 1)) {
  | (Some((firstItemMs, _)), Some((lastMs, _))) =>
    // STREAM_FIXTURE_DELAY_MS is 30 above; "at least 5 delays" is 150 ms.
    TestKit.check(
      "first item arrives at least 5 delays before the last event",
      lastMs -. firstItemMs >= 150.0,
    )
  | _ => TestKit.check("both a first item and a last event were received", false)
  }

  switch Array.find(received, ((_, e)) => e.event == "scene") {
  | None => TestKit.check("a scene event was received", false)
  | Some((_, e)) =>
    switch JsonCombinators.Json.parse(e.data) {
    | Error(_) => TestKit.check("scene event data parses as JSON", false)
    | Ok(json) =>
      switch Shared.decodeSceneReply(json) {
      | Error(_) => TestKit.check("scene event decodes with Shared.decodeSceneReply", false)
      | Ok(decoded) =>
        TestKit.check("scene event decodes with Shared.decodeSceneReply", true)
        // The stream path carries main's size and quarterSeen fields the
        // same as the non-streaming /api/scene route does.
        TestKit.check("the scene event reports quarterSeen", decoded.quarterSeen == true)
        TestKit.check(
          "the scene event carries an item's size from the stream",
          Array.get(decoded.items, 1)->Option.map(i => i.size) == Some("10 in"),
        )
      }
    }
  }

  Node.HttpServer.close(server, () => ())
  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "")
}

let runStopPath = async () => {
  TestKit.section("StreamRoute: client abort stops the upstream Claude request")

  let sseText = Node.Fs.readFileUtf8(
    Node.Path.join([cwd, "tests/fixtures/claude-stream.sse"]),
    "utf8",
  )
  let blocks = String.split(sseText, "\n\n")->Array.filter(b => String.trim(b) != "")

  let stubClosedRef = ref(false)
  let stub = Node.HttpServer.createServer((req, res) => {
    Node.HttpServer.onRequestClose(req, "close", () => stubClosedRef := true)
    Node.HttpServer.onResponseError(res, "error", () => ())
    Node.HttpServer.writeHead(res, 200, Dict.fromArray([("Content-Type", "text/event-stream")]))
    Node.HttpServer.flushHeaders(res)
    let rec go = (i: int): promise<unit> =>
      if stubClosedRef.contents || Node.HttpServer.writableEnded(res) {
        Promise.resolve()
      } else if i >= Array.length(blocks) {
        Node.HttpServer.endWithBody(res, "")
        Promise.resolve()
      } else {
        Node.HttpServer.write(res, Array.getUnsafe(blocks, i) ++ "\n\n")
        ClaudeStream.sleep(100)->Promise.then(() => go(i + 1))
      }
    go(0)->Promise.ignore
  })
  let stubPort = await Promise.make((resolve, _reject) =>
    Node.HttpServer.listen(stub, 0, "127.0.0.1", () => resolve(Node.HttpServer.address(stub).port))
  )

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

  let testController = Fetch.AbortController.make()
  let photo = Node.Fs.readFileBuffer(Node.Path.join([cwd, "tests/fixtures/table.jpg"]))
  let resp = await Fetch.fetchBuffer(
    "http://127.0.0.1:" ++ Int.toString(port) ++ "/api/scene/stream",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "image/jpeg")]),
      body: photo,
      signal: Fetch.AbortController.signal(testController),
    },
  )
  TestKit.check("POST /api/scene/stream (stub) responds 200", Fetch.status(resp) == 200)

  switch Fetch.body(resp) {
  | None => TestKit.check("response had a body to read", false)
  | Some(stream) => {
      let reader = Fetch.getReader(stream)
      let decoder = TextDecoder.make()
      let sseStateRef = ref(Sse.empty)
      let rec readUntilItem = async (): unit => {
        let chunk = await Fetch.read(reader)
        if chunk.done {
          ()
        } else {
          switch chunk.value {
          | None => await readUntilItem()
          | Some(bytes) => {
              let text = TextDecoder.decodeStream(decoder, bytes, {stream: true})
              let (state2, events) = Sse.feed(sseStateRef.contents, text)
              sseStateRef := state2
              switch Array.find(events, e => e.event == "item") {
              | Some(_) => Fetch.AbortController.abort(testController)
              | None => await readUntilItem()
              }
            }
          }
        }
      }
      await readUntilItem()
    }
  }

  // Give every wait a time limit: poll for up to 2 s, per the brief.
  let deadline = Date.now() +. 2000.0
  let rec waitForStubClose = async (): unit =>
    if stubClosedRef.contents || Date.now() > deadline {
      ()
    } else {
      await ClaudeStream.sleep(20)
      await waitForStubClose()
    }
  await waitForStubClose()
  TestKit.check("the stub sees its request closed within 2 s", stubClosedRef.contents)

  // The scene-log append is a synchronous fs write in the same reaction
  // chain that closes the upstream connection to the stub; this is slack
  // for the write to have landed, not a wait for more stream activity.
  await ClaudeStream.sleep(200)

  let logPath = Node.Path.join([dataDir, "scenes.jsonl"])
  TestKit.check("scenes.jsonl was written", Node.Fs.existsSync(logPath))
  let lines =
    String.trim(Node.Fs.readFileUtf8(logPath, "utf8"))
    ->String.split("\n")
    ->Array.filter(l => l != "")
  let stoppedLine = Array.find(lines, l =>
    switch JsonCombinators.Json.parse(l) {
    | Ok(json) => Json.boolField(json, "stopped") == Some(true)
    | Error(_) => false
    }
  )
  switch stoppedLine {
  | None => TestKit.check("a stopped scene-log line exists", false)
  | Some(line) =>
    switch JsonCombinators.Json.parse(line) {
    | Error(_) => TestKit.check("stopped line parses as JSON", false)
    | Ok(json) => {
        let items = Json.arrayField(json, "items")->Option.getOr([])
        TestKit.check("stopped line has at least one item", Array.length(items) > 0)
      }
    }
  }

  Node.HttpServer.close(server, () => ())
  Node.HttpServer.close(stub, () => ())
}

let run = async () => {
  await runHappyPath()
  await runStopPath()
}
