// POST /api/scene/stream, a max_tokens stop_reason: the stream path must
// follow the same rule as Server.res's non-streaming CutOff branch (see
// ClaudeCutOffTest.res). A cut-off reply is not a normal finish — no
// `done`, no `scene`, no eBay merge. It sends `error`, then `end` with
// status `failed`, and logs the scene it billed for: sceneId, model,
// error, stopReason, outputPath, cost. Fixture:
// tests/fixtures/cutoff/claude-stream.sse ends on stop_reason "max_tokens"
// after one item's JSON closes.

let cwd = Node.Process.cwd()

let readAllEvents = async (resp: Fetch.response): array<Sse.event> => {
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

let hasEvent = (events: array<Sse.event>, name: string): bool =>
  switch Array.find(events, e => e.event == name) {
  | Some(_) => true
  | None => false
  }

let run = async () => {
  TestKit.section("StreamRoute: a max_tokens stop_reason ends the scene as failed")

  // The stream path shares ClaudeClient.buildRequestBody with /api/scene,
  // so it already inherits the same prompt cap and max_tokens — check that
  // directly, the same way ClaudeCutOffTest.res checks it for /api/scene.
  let body = ClaudeClient.buildRequestBody(
    ~model=Shared.modelId(Shared.defaultModel),
    ~imageBase64="",
    ~structuredOutput=true,
    ~mode=ClaudeClient.Scene({width: 1800, height: 1039}),
  )
  TestKit.check(
    "the stream request also asks for max_tokens 16000",
    Json.intField(body, "max_tokens") == Some(16_000),
  )
  TestKit.check(
    "the stream request's prompt also caps the list at 30 items",
    String.includes(Json.stringField(body, "system")->Option.getOr(""), "List at most 30 items."),
  )

  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "10")

  let dataDir = Node.Path.join([Node.Os.tmpdir(), "reflip-test-" ++ Node.Crypto.randomUUID()])
  let config: Config.t = {
    Config.port: 0,
    fixtures: true,
    dataDir,
    fixturesDir: Node.Path.join([cwd, "tests/fixtures/cutoff"]),
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

  let received = await readAllEvents(resp)
  let kinds = Array.map(received, e => e.event)

  TestKit.check("an item found before the cutoff still streamed", hasEvent(received, "item"))
  TestKit.check("no done event on a max_tokens cutoff", !hasEvent(received, "done"))
  TestKit.check("no scene event on a max_tokens cutoff", !hasEvent(received, "scene"))
  TestKit.check("an error event was sent", hasEvent(received, "error"))
  TestKit.check(
    "end is the last event",
    Array.get(kinds, Array.length(kinds) - 1) == Some("end"),
  )

  switch Array.find(received, e => e.event == "error") {
  | None => TestKit.check("an error event exists to check its message", false)
  | Some(e) =>
    switch JsonCombinators.Json.parse(e.data) {
    | Error(_) => TestKit.check("error event data parses as JSON", false)
    | Ok(json) =>
      TestKit.check(
        "error message says reply cut off",
        Json.stringField(json, "message") == Some("reply cut off"),
      )
    }
  }

  switch Array.find(received, e => e.event == "end") {
  | None => TestKit.check("an end event exists to check its status", false)
  | Some(e) =>
    switch JsonCombinators.Json.parse(e.data) {
    | Error(_) => TestKit.check("end event data parses as JSON", false)
    | Ok(json) =>
      TestKit.check("end status is failed", Json.stringField(json, "status") == Some("failed"))
    }
  }

  // Same shape as Server.res's non-streaming CutOff branch, adapted to the
  // stream's own raw-events dump for outputPath — see ClaudeCutOffTest.res.
  let logPath = Node.Path.join([dataDir, "scenes.jsonl"])
  TestKit.check("scenes.jsonl was written", Node.Fs.existsSync(logPath))
  let logLines =
    String.trim(Node.Fs.readFileUtf8(logPath, "utf8"))
    ->String.split("\n")
    ->Array.filter(l => l != "")
  TestKit.check("scenes.jsonl has exactly one line", Array.length(logLines) == 1)
  switch Array.get(logLines, 0) {
  | None => TestKit.check("a cut-off scene-log line exists", false)
  | Some(line) =>
    switch JsonCombinators.Json.parse(line) {
    | Error(_) => TestKit.check("cut-off line parses as JSON", false)
    | Ok(logLine) => {
        TestKit.check(
          "the log line names the cut-off error",
          Json.stringField(logLine, "error") == Some("reply cut off"),
        )
        TestKit.check(
          "the log line has stopReason max_tokens",
          Json.stringField(logLine, "stopReason") == Some("max_tokens"),
        )
        let outputPath = Json.stringField(logLine, "outputPath")
        TestKit.check("the log line has an outputPath", outputPath->Option.isSome)
        TestKit.check(
          "the raw events file it points at exists",
          outputPath->Option.map(Node.Fs.existsSync)->Option.getOr(false),
        )
        let cost = Json.field(logLine, "cost")
        TestKit.check(
          "the log line's cost.outputTokens is 16000",
          cost->Option.flatMap(c => Json.intField(c, "outputTokens")) == Some(16_000),
        )
        TestKit.check(
          "the log line's cost.usd is positive",
          cost->Option.flatMap(c => Json.floatField(c, "usd"))->Option.getOr(0.0) > 0.0,
        )
      }
    }
  }

  Node.HttpServer.close(server, () => ())
  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "")
}
