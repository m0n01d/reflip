// ScanEvent: every SSE event round-trips through toSse -> Sse.encode ->
// Sse.feed -> decode, and decode rejects an unknown event name and
// malformed JSON. See docs/scan-ui.md §2 for the event contract this
// checks against StreamRoute.res and SceneStream.res.

let sampleReplyItem: Types.replyItem = {
  Types.name: "Pyrex nesting bowls",
  query: "vintage pyrex nesting mixing bowls set",
  confidence: 0.8,
  estimateLowUsd: 15.0,
  estimateHighUsd: 45.0,
  basis: "sold listings on eBay and WorthPoint",
  sources: ["ebay.com", "worthpoint.com"],
  ebay: Some({
    Types.count: 5,
    minUsd: 12.0,
    p25Usd: 18.0,
    medianUsd: 22.0,
    p75Usd: 30.0,
    maxUsd: 45.0,
  }),
  soldSearchUrl: "https://www.ebay.com/sch/i.html?_nkw=pyrex+bowls",
  size: "medium",
  box: Some({Types.x1: 10, y1: 20, x2: 300, y2: 250}),
  profit: Profit.estimate(
    ~lowUsd=15.0,
    ~highUsd=45.0,
    ~shipClass=Profit.Medium,
    ~tagPriceUsd=None,
  ),
}

let sampleSceneReply: Types.sceneReply = {
  Types.sceneId: "scene-abc-123",
  model: "claude-sonnet-5",
  fixture: true,
  outputPath: "/tmp/reflip-test/scene-abc-123.json",
  items: [sampleReplyItem],
  imageWidth: 1024,
  imageHeight: 768,
  timing: {Types.serverMs: 120.0, claudeMs: 4500.0, ebayMs: 300.0},
  cost: {
    Types.usd: 0.031,
    inputTokens: 1800,
    outputTokens: 420,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    webSearches: 2,
  },
  ebayNote: None,
  quarterSeen: false,
}

// toSse -> Sse.encode -> Sse.feed -> decode must reproduce `evt` exactly.
let roundTrip = (label: string, evt: ScanEvent.t): unit => {
  let (event, data) = ScanEvent.toSse(evt)
  let sseText = Sse.encode(~event, ~data)
  let (_, events) = Sse.feed(Sse.empty, sseText)
  switch events {
  | [e] =>
    TestKit.check(label ++ ": Sse.feed dispatches under the encoded name", e.event == event)
    switch ScanEvent.decode(~event=e.event, ~data=e.data) {
    | Ok(decoded) => TestKit.check(label ++ ": decodes back to an equal value", decoded == evt)
    | Error(msg) => TestKit.check(label ++ ": decode failed: " ++ msg, false)
    }
  | other =>
    TestKit.check(
      label ++ ": Sse.feed dispatched exactly one event, got " ++ Int.toString(Array.length(other)),
      false,
    )
  }
}

let run = () => {
  TestKit.section("ScanEvent (round-trip through Sse)")

  roundTrip(
    "photo-received",
    ScanEvent.PhotoReceived({sceneId: "scene-1", bytes: 245_000, width: 1024, height: 768}),
  )
  roundTrip("claude-started", ScanEvent.ClaudeStarted({t: 12.0, inputTokens: 1800}))
  roundTrip("thinking", ScanEvent.Thinking({t: 340.0}))
  roundTrip("tool-run", ScanEvent.ToolRun({t: 500.0, id: "srvtoolu_1", name: "code_execution"}))
  roundTrip(
    "tool-done",
    ScanEvent.ToolDone({t: 900.0, id: "srvtoolu_1", name: "code_execution", status: Some("success")}),
  )
  roundTrip(
    "tool-done (status=None)",
    ScanEvent.ToolDone({t: 900.0, id: "srvtoolu_1", name: "code_execution", status: None}),
  )
  roundTrip(
    "search-started",
    ScanEvent.SearchStarted({t: 520.0, id: "srvtoolu_2", query: Some("vintage pyrex bowls")}),
  )
  roundTrip(
    "search-started (query=None)",
    ScanEvent.SearchStarted({t: 520.0, id: "srvtoolu_2", query: None}),
  )
  roundTrip("search-done", ScanEvent.SearchDone({t: 700.0, id: "srvtoolu_2", count: 3}))
  roundTrip(
    "search-failed",
    ScanEvent.SearchFailed({t: 710.0, id: "srvtoolu_3", errorCode: "max_uses_exceeded"}),
  )
  roundTrip("box", ScanEvent.Box({t: 1200.0, index: 0, box: [10, 20, 300, 250]}))
  roundTrip("item", ScanEvent.Item({t: 1250.0, index: 0, item: sampleReplyItem}))
  roundTrip(
    "done",
    ScanEvent.Done({
      claudeMs: 4500.0,
      inputTokens: 1800,
      outputTokens: 420,
      webSearches: 2,
      usd: 0.031,
    }),
  )
  roundTrip("scene", ScanEvent.Scene(sampleSceneReply))
  roundTrip("error", ScanEvent.ErrorEvent({t: 4600.0, message: "item 1 rejected: unparsable JSON"}))
  roundTrip("stop", ScanEvent.Stop({t: 3000.0}))
  roundTrip("spot-started", ScanEvent.SpotStarted({t: 4700.0, inputTokens: 900}))
  roundTrip(
    "spot-item",
    ScanEvent.SpotItem({t: 4800.0, index: 0, name: "board game lot", box: [40, 60, 220, 300]}),
  )
  roundTrip(
    "spot-done",
    ScanEvent.SpotDone({t: 5200.0, claudeMs: 500.0, inputTokens: 900, outputTokens: 120, usd: 0.006}),
  )
  roundTrip("spot-failed", ScanEvent.SpotFailed({t: 5200.0, message: "spot pass timed out"}))
  roundTrip("end (done)", ScanEvent.End({t: 4650.0, status: ScanEvent.EndStatus.Done}))
  roundTrip("end (stopped)", ScanEvent.End({t: 3050.0, status: ScanEvent.EndStatus.Stopped}))
  roundTrip("end (failed)", ScanEvent.End({t: 900.0, status: ScanEvent.EndStatus.Failed}))
  roundTrip("end (timeout)", ScanEvent.End({t: 180_000.0, status: ScanEvent.EndStatus.Timeout}))

  TestKit.check(
    "an unknown event name returns Error",
    switch ScanEvent.decode(~event="not-a-real-event", ~data="{}") {
    | Error(_) => true
    | Ok(_) => false
    },
  )

  TestKit.check(
    "malformed JSON data returns Error",
    switch ScanEvent.decode(~event="thinking", ~data="{not valid json") {
    | Error(_) => true
    | Ok(_) => false
    },
  )

  TestKit.check(
    "an end event with an unrecognized status returns Error",
    switch ScanEvent.decode(
      ~event="end",
      ~data=JSON.stringify(Json.obj([("t", Json.num(1.0)), ("status", Json.str("bogus"))])),
    ) {
    | Error(_) => true
    | Ok(_) => false
    },
  )
}
