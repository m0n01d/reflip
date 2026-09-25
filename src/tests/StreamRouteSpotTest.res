// POST /api/scene/stream: the spot pass's own behavior next to the priced
// pass (docs/scan-ui.md brief, item 5). Four things this file checks: the
// fixture spot events arrive in order and interleave with the priced
// events, a spot failure leaves the priced scene done, `end` is always
// last, and a spot pass that runs past the priced pass's end gets
// aborted.
//
// tests/fixtures/spot/claude-spot.events.jsonl is built from the real
// spot-1 recording (docs/stream-spike/events/spot-1.events.jsonl.gz, this
// brief's item 4) with only its `ms` field rewritten: its first 60 lines
// keep their real order and payloads but land at 0-118 ms instead of
// their original 1864-2526 ms, which covers the first item's real close.
// The rest move out to 5000 ms or later. tests/fixtures/spot/
// claude-stream.sse is the default priced fixture (tests/fixtures/
// claude-stream.sse), copied unchanged. With STREAM_FIXTURE_DELAY_MS set
// low, the priced pass's 87 events finish in well under 5000 ms, so its
// end aborts the spot pass before the fixture's later, retimed items
// arrive.

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

// The first index in `events` whose kind is `name`, or None. A small
// manual loop instead of a stdlib search function, so this file does not
// depend on which one this ReScript version ships.
let indexOfKind = (events: array<Sse.event>, name: string): option<int> => {
  let rec go = (i: int): option<int> =>
    if i >= Array.length(events) {
      None
    } else if (Array.getUnsafe(events, i)).event == name {
      Some(i)
    } else {
      go(i + 1)
    }
  go(0)
}

let baseConfig = (~fixturesDir: string, ~dataDir: string): Config.t => {
  Config.port: 0,
  fixtures: true,
  dataDir,
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

// Covers: spot events interleave with the priced events, in order, and a
// spot pass that runs past the priced pass's end gets aborted.
let runInterleaveAndAbort = async () => {
  TestKit.section("StreamRoute: the spot pass interleaves, and a priced-pass end aborts it")

  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "3")

  let dataDir = Node.Path.join([Node.Os.tmpdir(), "reflip-test-" ++ Node.Crypto.randomUUID()])
  let config = baseConfig(~fixturesDir=Node.Path.join([cwd, "tests/fixtures/spot"]), ~dataDir)
  let {Server.server: server, port} = await Server.start(config)

  let resp = await postPhoto(port)
  TestKit.check("POST /api/scene/stream responds 200", Fetch.status(resp) == 200)

  let received = await readAllEvents(resp)
  let kinds = Array.map(received, e => e.event)

  TestKit.check("at least one spot-item arrived", hasEvent(received, "spot-item"))

  // Interleaving: a spot-item's position in the one ordered SSE stream
  // falls before the priced pass's own `done`, not after it -- proof the
  // two passes' events actually mix, rather than running one after the
  // other.
  TestKit.check(
    "a spot-item arrives before the priced pass's done",
    switch (indexOfKind(received, "spot-item"), indexOfKind(received, "done")) {
    | (Some(spotIdx), Some(doneIdx)) => spotIdx < doneIdx
    | _ => false
    },
  )

  // Abort: the retimed fixture has 31 items in total, but everything past
  // its first stretch moved out to 5000 ms or later -- well after the
  // priced pass (87 events, 3 ms apart) has already finished and called
  // finishSpot. So fewer than 31 spot-item events arrive, and the spot
  // pass never reaches its own natural Finished (spot-done).
  let spotItemCount = Array.filter(kinds, k => k == "spot-item")->Array.length
  TestKit.check(
    "fewer than the fixture's 31 items arrived, so the spot pass was cut off",
    spotItemCount > 0 && spotItemCount < 31,
  )
  TestKit.check(
    "no spot-done arrived, so the spot pass never finished on its own",
    !hasEvent(received, "spot-done"),
  )
  TestKit.check(
    "no spot-failed arrived either -- an abort past the priced end is not a failure",
    !hasEvent(received, "spot-failed"),
  )

  TestKit.check("end is the last event", Array.get(kinds, Array.length(kinds) - 1) == Some("end"))
  TestKit.check(
    "the priced pass still finished normally",
    hasEvent(received, "done") && hasEvent(received, "scene"),
  )

  Node.HttpServer.close(server, () => ())
  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "")
}

// Covers: a spot failure leaves the priced scene done, and end is last.
// Reuses the default tests/fixtures dir, which has no claude-spot
// fixture, so the spot pass ends in SpotPass.NoFixture -- the same path
// StreamRouteTest.res's own happy path already runs into (see that
// file's expectedKinds), checked again here on its own for this brief's
// item 5.
let runSpotFailureLeavesSceneDone = async () => {
  TestKit.section("StreamRoute: a spot failure leaves the priced scene done")

  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "5")

  let dataDir = Node.Path.join([Node.Os.tmpdir(), "reflip-test-" ++ Node.Crypto.randomUUID()])
  let config = baseConfig(~fixturesDir=Node.Path.join([cwd, "tests/fixtures"]), ~dataDir)
  let {Server.server: server, port} = await Server.start(config)

  let resp = await postPhoto(port)
  TestKit.check("POST /api/scene/stream responds 200", Fetch.status(resp) == 200)

  let received = await readAllEvents(resp)
  let kinds = Array.map(received, e => e.event)

  TestKit.check(
    "spot-failed arrived (no claude-spot fixture in tests/fixtures)",
    hasEvent(received, "spot-failed"),
  )
  TestKit.check("the priced pass still reached done", hasEvent(received, "done"))

  switch Array.find(received, e => e.event == "end") {
  | None => TestKit.check("an end event exists to check its status", false)
  | Some(e) =>
    switch JsonCombinators.Json.parse(e.data) {
    | Error(_) => TestKit.check("end event data parses as JSON", false)
    | Ok(json) =>
      TestKit.check(
        "end status is done despite the spot failure",
        Json.stringField(json, "status") == Some("done"),
      )
    }
  }
  TestKit.check("end is the last event", Array.get(kinds, Array.length(kinds) - 1) == Some("end"))

  switch Array.find(received, e => e.event == "scene") {
  | None => TestKit.check("a scene event was received", false)
  | Some(e) =>
    switch JsonCombinators.Json.parse(e.data) {
    | Error(_) => TestKit.check("scene event data parses as JSON", false)
    | Ok(json) =>
      TestKit.check(
        "scene event decodes with Shared.decodeSceneReply",
        switch Shared.decodeSceneReply(json) {
        | Ok(_) => true
        | Error(_) => false
        },
      )
    }
  }

  Node.HttpServer.close(server, () => ())
  Dict.set(Node.Process.env, "STREAM_FIXTURE_DELAY_MS", "")
}

let run = async () => {
  await runInterleaveAndAbort()
  await runSpotFailureLeavesSceneDone()
}
