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
  "box",
  "item",
  "box",
  "item",
  "box",
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
  TestKit.check(
    "a box event arrives for each item",
    Array.length(Array.filter(kinds, k => k == "box")) == 3,
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
  // Guard (CLAUDE.md hard rule 1): captures the body StreamRoute.handle
  // actually sends upstream, checked below against the eBay fixture's own
  // titles and prices, the same way GuardTest.res checks
  // ClaudeClient.buildRequestBody's output — this is the streaming path's
  // own request, a separate build step from that one.
  let capturedBodyRef: ref<option<string>> = ref(None)
  let stub = Node.HttpServer.createServer((req, res) => {
    // res's own "close", not req's: on this Node build, req's "close" fires
    // as soon as the incoming request body finishes arriving (normal
    // completion), not only on a real abrupt disconnect -- confirmed by
    // toggling it against the guard check's readBody(req) call, which drains
    // that body and made this fire early, stopping the stub's writes after
    // one block with no client abort in sight. res's "close" (proven
    // reliable earlier against a real client-abort fetch, see
    // probe_server_res_close.mjs) only fires on genuine connection teardown.
    Node.HttpServer.onClose(res, "close", () => stubClosedRef := true)
    Node.HttpServer.onResponseError(res, "error", () => ())
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
    // Read the whole request body to completion before writing any response
    // bytes. Node's incoming-message "data"/"end" listeners (readBody) and
    // this stub's own outgoing SSE writes share one socket; starting the
    // response while the body read is still in flight (the original,
    // now-reverted approach here) reproducibly deadlocked this exact test
    // on this Node build (node:internal/process/promises never scheduled
    // the second "data" event after the first SSE write) -- confirmed by
    // toggling readBody on and off with the rest of the test held constant.
    // The reflip client sends its whole JSON body in one call regardless of
    // the response, so reading it to completion first changes nothing this
    // guard check observes.
    Node.HttpServer.readBody(req)
    ->Promise.then(buf => {
        capturedBodyRef := Some(Node.Buffer.toStringWithEncoding(buf, "utf8"))
        Node.HttpServer.writeHead(res, 200, Dict.fromArray([("Content-Type", "text/event-stream")]))
        Node.HttpServer.flushHeaders(res)
        go(0)
      })
    ->Promise.ignore
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

  // Guard (CLAUDE.md hard rule 1): the stream route's own upstream request
  // must exclude eBay fixture data too.
  let fixturesDir = Node.Path.join([cwd, "tests/fixtures"])
  let ebayJson = EbayClient.searchFixture(fixturesDir, 0)
  let ebayItems = Json.arrayField(ebayJson, "itemSummaries")->Option.getOr([])
  let guardTitles = Array.filterMap(ebayItems, item => Json.stringField(item, "title"))
  let guardPrices = Array.filterMap(ebayItems, item =>
    Json.field(item, "price")->Option.flatMap(p => Json.stringField(p, "value"))
  )
  switch capturedBodyRef.contents {
  | None => TestKit.check("the stub captured a request body to guard-check", false)
  | Some(sentBody) =>
    TestKit.check("the captured request body is non-empty", sentBody != "")
    Array.forEach(guardTitles, title =>
      TestKit.check(
        "stream request body excludes eBay title \"" ++ title ++ "\"",
        !String.includes(sentBody, title),
      )
    )
    Array.forEach(guardPrices, price =>
      TestKit.check(
        "stream request body excludes eBay price " ++ price,
        !String.includes(sentBody, price),
      )
    )
  }

  Node.HttpServer.close(server, () => ())
  Node.HttpServer.close(stub, () => ())
}

// Bug: ClaudeStream.runLive used to catch only "TimeoutError" and
// "AbortError" by exception name. A connection that just dies mid-stream
// (the stub below sends one real event, then destroys the socket instead
// of ending cleanly) throws a plain "TypeError: terminated", which used to
// escape runLive as an unhandled rejection all the way to Server.res's
// server-level handler — after StreamRoute.handle had already sent the SSE
// 200 headers, so that handler's own writeHead(500) then threw
// ERR_HTTP_HEADERS_SENT and crashed the process (exit code 1). If this
// regresses, this test's own process dies before it can report red.
let runFetchFailsMidStreamPath = async () => {
  TestKit.section("StreamRoute: a Claude connection dying mid-stream ends the SSE stream, not the process")

  let sseText = Node.Fs.readFileUtf8(
    Node.Path.join([cwd, "tests/fixtures/claude-stream.sse"]),
    "utf8",
  )
  let blocks = String.split(sseText, "\n\n")->Array.filter(b => String.trim(b) != "")

  let stub = Node.HttpServer.createServer((_req, res) => {
    Node.HttpServer.onResponseError(res, "error", () => ())
    Node.HttpServer.writeHead(res, 200, Dict.fromArray([("Content-Type", "text/event-stream")]))
    Node.HttpServer.flushHeaders(res)
    TestKit.check(
      "the stub's own response reports headersSent once writeHead ran",
      Node.HttpServer.headersSent(res),
    )
    // One real event, so ClaudeStream.runLive gets past onHeaders and into
    // its read loop before the connection dies, instead of failing on the
    // very first fetch.
    Node.HttpServer.write(res, Array.getUnsafe(blocks, 0) ++ "\n\n")
    ClaudeStream.sleep(50)
    ->Promise.then(() => {
        Node.HttpServer.destroy(res)
        Promise.resolve()
      })
    ->Promise.ignore
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

  let photo = Node.Fs.readFileBuffer(Node.Path.join([cwd, "tests/fixtures/table.jpg"]))
  let resp = await Fetch.fetchBuffer(
    "http://127.0.0.1:" ++ Int.toString(port) ++ "/api/scene/stream",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "image/jpeg")]),
      body: photo,
      signal: Fetch.AbortSignal.timeout(15_000),
    },
  )
  TestKit.check(
    "POST /api/scene/stream still answers 200 (headers went out before the drop)",
    Fetch.status(resp) == 200,
  )

  let received = await readAllEvents(resp, Date.now())
  switch Array.find(received, ((_, e)) => e.event == "error") {
  | None => TestKit.check("the client gets an error event instead of a dropped connection", false)
  | Some(_) => TestKit.check("the client gets an error event instead of a dropped connection", true)
  }
  switch Array.find(received, ((_, e)) => e.event == "scene") {
  | None => TestKit.check("no scene event was sent, since the stream failed", true)
  | Some(_) => TestKit.check("no scene event was sent, since the stream failed", false)
  }

  Node.HttpServer.close(server, () => ())
  Node.HttpServer.close(stub, () => ())
}

// Bug: buildSceneReply's eBay merge (EbayClient.statsFor, via Promise.all)
// can reject outside fixture mode, and EbayClient.res itself catches
// nothing. A bad eBay client id proves it with no network call at all:
// Fetch.btoa throws a DOMException ("InvalidCharacterError") synchronously
// on a client id with a character outside Latin1, before
// EbayClient.fetchToken ever calls fetch — so this never reaches
// api.ebay.com. That rejection used to escape StreamRoute.handle's
// Completed branch uncaught, after the SSE 200 headers were already sent:
// the same crash as the test above, from a different call site
// (buildSceneReply, not ClaudeStream.runLive).
let runEbayThrowsPath = async () => {
  TestKit.section("StreamRoute: an eBay lookup that throws still ends the SSE stream with an error event")

  let sseText = Node.Fs.readFileUtf8(
    Node.Path.join([cwd, "tests/fixtures/claude-stream.sse"]),
    "utf8",
  )
  let blocks = String.split(sseText, "\n\n")->Array.filter(b => String.trim(b) != "")

  let stub = Node.HttpServer.createServer((_req, res) => {
    Node.HttpServer.onResponseError(res, "error", () => ())
    Node.HttpServer.writeHead(res, 200, Dict.fromArray([("Content-Type", "text/event-stream")]))
    Node.HttpServer.flushHeaders(res)
    Node.HttpServer.write(res, Array.join(blocks, "\n\n") ++ "\n\n")
    Node.HttpServer.endWithBody(res, "")
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
    // "中" is outside Latin1, so EbayClient.fetchToken's own
    // Fetch.btoa(clientId ++ ":" ++ secret) throws before any fetch runs.
    ebayClientId: Some("bad-中-client-id"),
    ebayClientSecret: Some("does-not-matter"),
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
    "http://127.0.0.1:" ++ Int.toString(port) ++ "/api/scene/stream",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "image/jpeg")]),
      body: photo,
      signal: Fetch.AbortSignal.timeout(15_000),
    },
  )
  TestKit.check("POST /api/scene/stream still answers 200", Fetch.status(resp) == 200)

  let received = await readAllEvents(resp, Date.now())
  switch Array.find(received, ((_, e)) => e.event == "error") {
  | None => TestKit.check("an error event was received", false)
  | Some(_) => TestKit.check("an error event was received", true)
  }
  switch Array.find(received, ((_, e)) => e.event == "scene") {
  | None => TestKit.check("no scene event was sent, since buildSceneReply threw", true)
  | Some(_) => TestKit.check("no scene event was sent, since buildSceneReply threw", false)
  }

  Node.HttpServer.close(server, () => ())
  Node.HttpServer.close(stub, () => ())
}

let run = async () => {
  await runHappyPath()
  await runStopPath()
  await runFetchFailsMidStreamPath()
  await runEbayThrowsPath()
}
