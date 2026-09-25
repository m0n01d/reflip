// FixtureReplay: timed delivery at ms/speed measured from the replay's own
// start (not a sum of gaps), the .gz fixture form decoding to the same
// events as the plain form, and EbayClient.res's fallback for an index past
// the last recorded ebay-search-<n>.json (docs/scan-ui.md's fixture-mode
// contract: no data, not a crash).

let checkSameEvents = (
  label: string,
  a: array<FixtureReplay.recorded>,
  b: array<FixtureReplay.recorded>,
): unit => {
  TestKit.check(label ++ " count", Array.length(a) == Array.length(b))
  for i in 0 to Array.length(a) - 1 {
    switch (Array.get(a, i), Array.get(b, i)) {
    | (Some(ra), Some(rb)) =>
      TestKit.check(label ++ " ms matches", ra.ms == rb.ms)
      TestKit.check(label ++ " event matches", ra.evt.event == rb.evt.event)
      TestKit.check(label ++ " data matches", ra.evt.data == rb.evt.data)
    | _ => TestKit.check(label ++ " has enough events", false)
    }
  }
}

let run = async () => {
  TestKit.section("FixtureReplay")

  let cwd = Node.Process.cwd()
  let replayDir = Node.Path.join([cwd, "tests/fixtures/replay"])
  let plainPath = Node.Path.join([replayDir, "sample.events.jsonl"])
  let gzPath = plainPath ++ ".gz"

  let events = FixtureReplay.readEvents(plainPath)
  TestKit.check("sample fixture decodes 5 events", Array.length(events) == 5)

  // Timed delivery: the fixture spans 2000ms of recorded offsets, so at
  // speed 10 it should land near 200ms of real time -- measured from
  // play()'s own start, not a running sum of inter-event gaps, so it can't
  // drift. Fetch.AbortSignal.timeout(5_000) is this test's time limit: if
  // play() were ever to hang, it stops at 5s instead of hanging the suite.
  let delivered: array<Sse.event> = []
  let t0 = Date.now()
  await FixtureReplay.play(
    events,
    ~speed=10.0,
    ~stop=Fetch.AbortSignal.timeout(5_000),
    ~onEvent=evt => Array.push(delivered, evt)->ignore,
  )
  let elapsedMs = Date.now() -. t0
  TestKit.check(
    "speed 10 replay of a ~2000ms fixture takes 150-800ms, got " ++ Float.toString(elapsedMs),
    elapsedMs >= 150.0 && elapsedMs <= 800.0,
  )
  TestKit.check("all 5 events delivered", Array.length(delivered) == 5)
  for i in 0 to Array.length(events) - 1 {
    switch (Array.get(delivered, i), Array.get(events, i)) {
    | (Some(d), Some(r)) => TestKit.check("delivered[" ++ Int.toString(i) ++ "] in order", d.event == r.evt.event)
    | _ => TestKit.check("delivered has enough events", false)
    }
  }

  // The .gz form decodes to the same events as the plain form.
  let gzEvents = FixtureReplay.readEvents(gzPath)
  checkSameEvents("gz vs plain", gzEvents, events)

  // EbayClient fixture mode: tests/fixtures/ only has ebay-search-0/1/2, so
  // an item at index 99 has no matching file. That must give the item null
  // eBay data, not throw.
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
  let missingItem: Types.claudeItem = {
    name: "item with no eBay fixture",
    maker: None,
    query: "anything",
    estimateLowUsd: 1.0,
    estimateHighUsd: 2.0,
    basis: "test",
    confidence: 0.5,
    sources: [],
    where: None,
    size: "",
    box: None,
  }
  let (stats, note) = await EbayClient.statsFor(config, 99, missingItem)
  TestKit.check("missing ebay-search-99.json gives ebay null", stats == None)
  TestKit.check("missing ebay-search-99.json gives no error note", note == None)
}
