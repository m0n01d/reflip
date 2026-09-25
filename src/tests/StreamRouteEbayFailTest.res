// StreamRoute.handle when the eBay step fails (review finding R2). The
// injected buildSceneReply below rejects, as the real one does when an
// eBay call rejects. The scene must still send `scene`, with each item's
// `ebay` null and an `ebayNote` that says the eBay lookup failed. The
// `error` event with the message comes just before `scene`, and `end`
// keeps Claude's own outcome: `done` after a normal finish, `stopped`
// after a Stop. Before this fix, the scene ended as `failed`, so after a
// Stop the page showed "Could not finish" and a Try again button that
// threw away the items.

let cwd = Node.Process.cwd()

let failMessage = "eBay token request failed: connection refused"

// Stands in for Server.buildSceneReply. It rejects the way the eBay merge
// rejects when one eBay call fails.
let rejectingBuildSceneReply = async (
  ~config as _: Config.t,
  ~model as _: string,
  ~sentWidth as _: int,
  ~sentHeight as _: int,
  ~serverStart as _: float,
  ~claudeMs as _: float,
  ~sceneId as _: string,
  ~outputPath as _: string,
  ~items as _: array<Types.claudeItem>,
  ~usage as _: Types.usage,
  ~quarterSeen as _: bool,
): Types.sceneReply => JsError.throwWithMessage(failMessage)

// Fixture mode: Claude replays tests/fixtures/claude-stream.sse at
// STREAM_FIXTURE_DELAY_MS per event. There is no spot fixture there, so
// the spot pass sends spot-failed, which the checks below ignore.
let config = (~dataDir: string): Config.t => {
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

// A server with only the stream route on it, so the test can inject
// buildSceneReply. Server.start always passes the real one.
let startRoute = async (config: Config.t) => {
  let server = Node.HttpServer.createServer((req, res) =>
    Node.HttpServer.readBody(req)
    ->Promise.then(body =>
      StreamRoute.handle(
        ~config,
        ~model=Shared.modelId(Shared.defaultModel),
        ~body,
        ~res,
        ~buildSceneReply=rejectingBuildSceneReply,
      )
    )
    ->Promise.ignore
  )
  let port = await Promise.make((resolve, _reject) =>
    Node.HttpServer.listen(server, 0, "127.0.0.1", () =>
      resolve(Node.HttpServer.address(server).port)
    )
  )
  (server, port)
}

// Reads the whole SSE reply. `onEvent` sees each event as it arrives, so
// the stop case can ask for a Stop in the middle of the scene.
let readAllEvents = async (resp: Fetch.response, ~onEvent: Sse.event => unit): array<Sse.event> => {
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
              Array.forEach(events, e => {
                Array.push(received, e)->ignore
                onEvent(e)
              })
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

let postPhoto = (port: int): promise<Fetch.response> => {
  let photo = Node.Fs.readFileBuffer(Node.Path.join([cwd, "tests/fixtures/table.jpg"]))
  Fetch.fetchBuffer(
    "http://127.0.0.1:" ++ Int.toString(port) ++ "/api/scene/stream",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "image/jpeg")]),
      body: photo,
      signal: Fetch.AbortSignal.timeout(15_000),
    },
  )
}

let parseData = (e: Sse.event): option<JSON.t> =>
  switch JsonCombinators.Json.parse(e.data) {
  | Ok(json) => Some(json)
  | Error(_) => None
  }

// The checks both cases share. `lead` is the scene event just before the
// eBay `error`: `done` after a normal finish, `stop` after a Stop.
let checkTail = (events: array<Sse.event>, ~lead: string, ~endStatus: string) => {
  let kinds = Array.map(events, e => e.event)
  let sceneEvents = Array.filter(events, e => !String.startsWith(e.event, "spot-"))
  let sceneKinds = Array.map(sceneEvents, e => e.event)
  let n = Array.length(sceneKinds)
  TestKit.check(
    "the scene ends in " ++
    lead ++
    ", error, scene, end (spot events aside) -- got " ++
    Array.join(kinds, ","),
    n >= 4 &&
    sceneKinds[n - 4] == Some(lead) &&
    sceneKinds[n - 3] == Some("error") &&
    sceneKinds[n - 2] == Some("scene") &&
    sceneKinds[n - 1] == Some("end"),
  )
  TestKit.check(
    "end is the last event, and there is exactly one",
    kinds[Array.length(kinds) - 1] == Some("end") &&
      Array.filter(kinds, k => k == "end")->Array.length == 1,
  )
  switch sceneEvents[n - 3]->Option.flatMap(parseData) {
  | None => TestKit.check("the error event data parses", false)
  | Some(json) =>
    TestKit.check(
      "the error message says the eBay lookup failed, with the cause",
      switch Json.stringField(json, "message") {
      | Some(m) => String.includes(m, "eBay lookup failed") && String.includes(m, failMessage)
      | None => false
      },
    )
  }
  switch sceneEvents[n - 2]->Option.flatMap(parseData) {
  | None => TestKit.check("the scene event data parses", false)
  | Some(json) => {
      let items = Json.arrayField(json, "items")->Option.getOr([])
      TestKit.check("the scene has at least one item", Array.length(items) > 0)
      TestKit.check(
        "every item's ebay is null",
        Array.every(items, item =>
          switch item {
          | JSON.Object(d) => Dict.get(d, "ebay") == Some(JSON.Null)
          | _ => false
          }
        ),
      )
      TestKit.check(
        "ebayNote says the eBay lookup failed",
        switch Json.stringField(json, "ebayNote") {
        | Some(note) => String.includes(note, "eBay lookup failed")
        | None => false
        },
      )
    }
  }
  switch sceneEvents[n - 1]->Option.flatMap(parseData) {
  | None => TestKit.check("the end event data parses", false)
  | Some(json) =>
    TestKit.check(
      "end status is " ++ endStatus,
      Json.stringField(json, "status") == Some(endStatus),
    )
  }
}

let runDone = async () => {
  TestKit.section("StreamRoute: a failed eBay step still sends the scene, then end done")
  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "3")
  let dataDir = Node.Path.join([Node.Os.tmpdir(), "reflip-test-" ++ Node.Crypto.randomUUID()])
  let (server, port) = await startRoute(config(~dataDir))
  let resp = await postPhoto(port)
  TestKit.check("POST /api/scene/stream responds 200", Fetch.status(resp) == 200)
  let events = await readAllEvents(resp, ~onEvent=_ => ())
  checkTail(events, ~lead="done", ~endStatus="done")
  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "")
  Node.HttpServer.close(server, () => ())
}

let runStopped = async () => {
  TestKit.section(
    "StreamRoute: a failed eBay step after a Stop still sends the scene, then end stopped",
  )
  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "40")
  let dataDir = Node.Path.join([Node.Os.tmpdir(), "reflip-test-" ++ Node.Crypto.randomUUID()])
  let (server, port) = await startRoute(config(~dataDir))
  let resp = await postPhoto(port)
  TestKit.check("POST /api/scene/stream responds 200", Fetch.status(resp) == 200)
  let sceneIdRef = ref("")
  let stopSentRef = ref(false)
  let events = await readAllEvents(resp, ~onEvent=e =>
    switch e.event {
    | "photo-received" =>
      sceneIdRef :=
        parseData(e)->Option.flatMap(j => Json.stringField(j, "sceneId"))->Option.getOr("")
    | "item" if !stopSentRef.contents => {
        stopSentRef := true
        SceneRegistry.requestStop(sceneIdRef.contents)->ignore
      }
    | _ => ()
    }
  )
  TestKit.check("a Stop was sent after the first item", stopSentRef.contents)
  checkTail(events, ~lead="stop", ~endStatus="stopped")
  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "")
  Node.HttpServer.close(server, () => ())
}

let run = async () => {
  await runDone()
  await runStopped()
}
