// Tests for src/web/ScanState.res: the pure fold over ScanEvent.t, and the
// sticker numbering/takeover rules from docs/scan-ui.md. No network, no
// DOM — everything here is data in, data out.

let cwd = Node.Process.cwd()

let foldStep = (m: ScanState.model, evt: ScanEvent.t): ScanState.model =>
  ScanState.update(m, GotEvent(Ok(evt)))

let testItem = (
  ~name="Item",
  ~estimateLowUsd=25.0,
  ~estimateHighUsd=40.0,
  (),
): Types.replyItem => {
  name,
  query: name,
  confidence: 0.6,
  estimateLowUsd,
  estimateHighUsd,
  basis: "test fixture",
  sources: [],
  ebay: None,
  soldSearchUrl: "",
  size: "",
  box: None,
}

// -- The real fixture transcript -------------------------------------------
// tests/fixtures/scan-events-3.sse, captured 2026-09-25 against the fixture
// server: `FIXTURES=1 PORT=8791 npm start`, then
// `curl -sN -X POST --data-binary @tests/fixtures/table.jpg
//   -H 'content-type: image/jpeg' http://127.0.0.1:8791/api/scene/stream`.
// This exercises Sse.feed, ScanEvent.decode and ScanState.update together
// end to end, on bytes the server actually sent — not a hand-built event.
let decodeAll = (raw: string): array<ScanEvent.t> => {
  let (_, events) = Sse.feed(Sse.empty, raw)
  events->Array.filterMap((e: Sse.event) =>
    switch ScanEvent.decode(~event=e.event, ~data=e.data) {
    | Ok(evt) => Some(evt)
    | Error(_) => None
    }
  )
}

let runTranscript = () => {
  TestKit.section("ScanState: the real fixture transcript")
  let path = Node.Path.join([cwd, "tests/fixtures/scan-events-3.sse"])
  let raw = Node.Fs.readFileUtf8(path, "utf8")
  let (_, sseEvents) = Sse.feed(Sse.empty, raw)
  TestKit.check("the transcript has 15 real SSE events, no comments counted", Array.length(sseEvents) == 15)
  let events = decodeAll(raw)
  TestKit.check("every event in the transcript decodes", Array.length(events) == Array.length(sseEvents))
  let m = events->Array.reduce(ScanState.initialModel, foldStep)
  // eventCount lived on ScanState.model here before bug D (288738f
  // review): it was unused and drifted from ScanApi's own
  // localEventCount, which is the one counter now — see ScanApiTest.res.
  TestKit.check("phase ended done", m.phase == Ended(ScanEvent.EndStatus.Done))
  TestKit.check(
    "3 items landed, each with no prior box event, each got its own sticker",
    Array.length(ScanState.visibleStickers(m)) == 3,
  )
  TestKit.check(
    "all 3 are gems (this fixture's items are all >= $20 high)",
    Array.length(ScanState.gems(m)) == 3,
  )
  TestKit.check("scene reply landed", m.sceneReply->Option.isSome)
  TestKit.check("a run receipt is available once done", ScanState.receipt(m)->Option.isSome)
}

// -- Numbering order ----------------------------------------------------
// The first box or spot-item to land gets sticker 1, in landing order —
// not in wire-index order and not in item-completion order.
let runNumbering = () => {
  TestKit.section("ScanState: sticker numbering follows landing order")
  let events: array<ScanEvent.t> = [
    ScanEvent.Box({t: 100.0, index: 1, box: [10, 10, 20, 20]}), // lands first -> sticker 1, wire index 1
    ScanEvent.Box({t: 200.0, index: 0, box: [30, 30, 40, 40]}), // lands second -> sticker 2, wire index 0
    ScanEvent.Item({t: 300.0, index: 0, item: testItem(~name="Zero", ())}), // fills sticker 2
    ScanEvent.Item({t: 400.0, index: 1, item: testItem(~name="One", ())}), // fills sticker 1
  ]
  let m = events->Array.reduce(ScanState.initialModel, foldStep)
  let stickers = ScanState.visibleStickers(m)
  TestKit.check("two stickers landed", Array.length(stickers) == 2)
  switch stickers {
  | [first, second] => {
      TestKit.check("sticker 1 is the first box to land (wire index 1)", first.number == 1)
      TestKit.check(
        "sticker 1 carries wire index 1's item (\"One\"), not the landing order of the item event",
        first.item->Option.mapOr(false, i => i.name == "One"),
      )
      TestKit.check("sticker 2 is the second box to land (wire index 0)", second.number == 2)
      TestKit.check(
        "sticker 2 carries wire index 0's item (\"Zero\")",
        second.item->Option.mapOr(false, i => i.name == "Zero"),
      )
    }
  | _ => TestKit.check("unreachable: expected exactly 2 stickers", false)
  }
}

// -- Spot takeover at IoU 0.5 and just below it --------------------------
let runTakeover = () => {
  TestKit.section("ScanState: a priced item takes over a spot sticker at IoU >= 0.5")
  // Box A [0,0,100,100] (area 10000) vs box B [0,0,100,50] (area 5000):
  // intersection is B itself (5000), union is 10000, IoU = 0.5 exactly.
  let atThreshold: array<ScanEvent.t> = [
    // sets sentWidth/sentHeight so toBox below actually decodes the raw
    // boxes instead of short-circuiting to None (initialModel starts at
    // 0x0; a real transcript always sends photo-received first, per
    // docs/scan-ui.md §2). 1000x1000 fits Sonnet5's high tier
    // (ImageSize.highTier, maxEdge 2576), so no resize happens and the
    // scale factor is exactly 1.0 — the raw box coordinates below pass
    // through unchanged, matching the IoU arithmetic in the comments.
    ScanEvent.PhotoReceived({sceneId: "test-scene", bytes: 50000, width: 1000, height: 1000}),
    ScanEvent.SpotItem({t: 100.0, index: 0, name: "Something", box: [0, 0, 100, 100]}), // sticker 1 (spot)
    ScanEvent.Box({t: 200.0, index: 5, box: [0, 0, 100, 50]}), // sticker 2 (its own box)
    ScanEvent.Item({t: 300.0, index: 5, item: testItem(~name="Priced", ())}),
  ]
  let m1 = atThreshold->Array.reduce(ScanState.initialModel, foldStep)
  let visible1 = ScanState.visibleStickers(m1)
  TestKit.check("at IoU 0.5 exactly, the item takes over the spot sticker: only 1 visible sticker", Array.length(visible1) == 1)
  switch visible1 {
  | [only] => {
      TestKit.check("the surviving sticker kept the spot sticker's number (1)", only.number == 1)
      TestKit.check(
        "the surviving sticker carries the priced item's data",
        only.item->Option.mapOr(false, i => i.name == "Priced"),
      )
    }
  | _ => TestKit.check("unreachable: expected exactly 1 visible sticker", false)
  }
  TestKit.check(
    "the box-created sticker (2) is marked superseded, pointing at 1",
    switch Array.get(m1.stickers, 1) {
    | Some(s) => s.supersededBy == Some(1)
    | None => false
    },
  )

  // Box A [0,0,100,100] (area 10000) vs box B [50,0,150,100] (area 10000):
  // intersection [50,0,100,100] = 5000, union = 15000, IoU = 1/3 < 0.5.
  let belowThreshold: array<ScanEvent.t> = [
    ScanEvent.PhotoReceived({sceneId: "test-scene", bytes: 50000, width: 1000, height: 1000}),
    ScanEvent.SpotItem({t: 100.0, index: 0, name: "Something else", box: [0, 0, 100, 100]}), // sticker 1 (spot)
    ScanEvent.Box({t: 200.0, index: 5, box: [50, 0, 150, 100]}), // sticker 2 (its own box)
    ScanEvent.Item({t: 300.0, index: 5, item: testItem(~name="Also priced", ())}),
  ]
  let m2 = belowThreshold->Array.reduce(ScanState.initialModel, foldStep)
  let visible2 = ScanState.visibleStickers(m2)
  TestKit.check(
    "below IoU 0.5, no takeover: both stickers stay visible",
    Array.length(visible2) == 2,
  )
  TestKit.check(
    "the spot sticker (1) stays unmatched, no item",
    switch Array.get(visible2, 0) {
    | Some(s) => s.item->Option.isNone
    | None => false
    },
  )
  TestKit.check(
    "the priced item filled its own box-created sticker (2) instead",
    switch Array.get(visible2, 1) {
    | Some(s) => s.item->Option.mapOr(false, i => i.name == "Also priced")
    | None => false
    },
  )
}

// -- "not priced" after end ----------------------------------------------
let runNotPriced = () => {
  TestKit.section("ScanState: an unmatched spot sticker shows \"not priced\" once ended")
  let events: array<ScanEvent.t> = [
    ScanEvent.SpotItem({t: 100.0, index: 0, name: "Lonely spot", box: [0, 0, 10, 10]}),
    ScanEvent.End({t: 5000.0, status: ScanEvent.EndStatus.Done}),
  ]
  let m = events->Array.reduce(ScanState.initialModel, foldStep)
  TestKit.check("the scan is ended", ScanState.isEnded(m))
  TestKit.check(
    "the spot sticker still has no item — the view's cue to print \"not priced\"",
    switch Array.get(m.stickers, 0) {
    | Some(s) => s.item->Option.isNone
    | None => false
    },
  )
}

// -- A stop ---------------------------------------------------------------
let runStop = () => {
  TestKit.section("ScanState: StopTapped, then the authoritative end")
  let m0 = ScanState.update({...ScanState.initialModel, phase: Live}, StopTapped)
  TestKit.check("stopRequested is set", m0.stopRequested)
  TestKit.check("headline reads \"Stopping\" before the server confirms", ScanState.headline(m0) == "Stopping")
  let m1 = ScanState.update(m0, GotEvent(Ok(ScanEvent.End({t: 4000.0, status: ScanEvent.EndStatus.Stopped}))))
  TestKit.check("phase becomes Ended(Stopped)", m1.phase == Ended(ScanEvent.EndStatus.Stopped))
  TestKit.check("headline reads \"Stopped\"", ScanState.headline(m1) == "Stopped")
}

// -- A timeout --------------------------------------------------------------
let runTimeout = () => {
  TestKit.section("ScanState: the 3:00 time limit ends the scan on its own")
  let m0 = {...ScanState.initialModel, phase: Live}
  let m1 = ScanState.update(m0, GotEvent(Ok(ScanEvent.End({t: 180_000.0, status: ScanEvent.EndStatus.Timeout}))))
  TestKit.check("phase becomes Ended(Timeout)", m1.phase == Ended(ScanEvent.EndStatus.Timeout))
  TestKit.check("headline reads \"Stopped at 3:00\"", ScanState.headline(m1) == "Stopped at 3:00")
  TestKit.check("the clock reads 3:00", ScanState.clock(m1) == "3:00")
}

// -- A replay split at n gives the same model as one pass -----------------
// ScanApi.res's reconnect resumes a live stream partway through; the fold
// itself must not care where the split falls.
let runReplaySplit = () => {
  TestKit.section("ScanState: splitting the transcript and folding in two passes matches one pass")
  let path = Node.Path.join([cwd, "tests/fixtures/scan-events-3.sse"])
  let raw = Node.Fs.readFileUtf8(path, "utf8")
  let events = decodeAll(raw)
  let onePass = events->Array.reduce(ScanState.initialModel, foldStep)
  [3, 7, 12]->Array.forEach(n => {
    let first = events->Array.slice(~start=0, ~end=n)
    let rest = events->Array.slice(~start=n, ~end=Array.length(events))
    let twoPass =
      rest->Array.reduce(first->Array.reduce(ScanState.initialModel, foldStep), foldStep)
    TestKit.check("split at " ++ Int.toString(n) ++ ": same phase", onePass.phase == twoPass.phase)
    TestKit.check(
      "split at " ++ Int.toString(n) ++ ": same sticker count",
      Array.length(onePass.stickers) == Array.length(twoPass.stickers),
    )
    TestKit.check(
      "split at " ++ Int.toString(n) ++ ": same gem count",
      Array.length(ScanState.gems(onePass)) == Array.length(ScanState.gems(twoPass)),
    )
  })
}

// -- A failed first POST (bug A, 288738f review) ---------------------------
// ScanApi.res dispatches this when the initial POST fails outright, or
// when a reconnect never got a scene id to use — either way the old code
// left `phase` stuck at Sending ("Sending photo" forever) and dropped the
// reason. SendFailed must move the scan to a terminal state and keep the
// reason, the same way an `Ended` from the server would.
let runSendFailed = () => {
  TestKit.section("ScanState: SendFailed ends the scan instead of hanging at \"Sending photo\"")
  let m0 = {...ScanState.initialModel, phase: Sending}
  TestKit.check("headline reads \"Sending photo\" before the failure", ScanState.headline(m0) == "Sending photo")
  TestKit.check("connection state is Live before the failure", ScanState.connectionState(m0) == Live)
  let m1 = ScanState.update(m0, SendFailed("the server said 503"))
  TestKit.check("phase becomes Ended(Failed)", m1.phase == Ended(ScanEvent.EndStatus.Failed))
  TestKit.check(
    "headline reads \"Could not finish\", not stuck on \"Sending photo\"",
    ScanState.headline(m1) == "Could not finish",
  )
  TestKit.check("connection state is Failed", ScanState.connectionState(m1) == Failed)
  TestKit.check("exactly one error recorded, not dropped", Array.length(m1.errors) == 1)
  TestKit.check(
    "the reason is kept verbatim",
    switch Array.get(m1.errors, 0) {
    | Some((_, msg)) => msg == "the server said 503"
    | None => false
    },
  )
  TestKit.check("stickers already found are kept, not cleared", Array.length(m1.stickers) == Array.length(m0.stickers))
}

// -- The connection-state derived value -------------------------------------
let runConnectionState = () => {
  TestKit.section("ScanState.connectionState: live, reconnecting, failed")
  TestKit.check(
    "Ready is Live",
    ScanState.connectionState(ScanState.initialModel) == Live,
  )
  TestKit.check(
    "Live phase, not reconnecting, is Live",
    ScanState.connectionState({...ScanState.initialModel, phase: Live}) == Live,
  )
  TestKit.check(
    "reconnecting flips it to Reconnecting regardless of phase",
    ScanState.connectionState({...ScanState.initialModel, phase: Live, reconnecting: true}) == Reconnecting,
  )
  TestKit.check(
    "Ended(Failed) is Failed",
    ScanState.connectionState({...ScanState.initialModel, phase: Ended(ScanEvent.EndStatus.Failed)}) == Failed,
  )
  TestKit.check(
    "Ended(Done) is Live, not Failed — the scan finishing on purpose is not a connection failure",
    ScanState.connectionState({...ScanState.initialModel, phase: Ended(ScanEvent.EndStatus.Done)}) == Live,
  )
  TestKit.check(
    "reconnecting wins over a stale Ended(Failed) from before a fresh NewScan",
    ScanState.connectionState({...ScanState.initialModel, phase: Ended(ScanEvent.EndStatus.Failed), reconnecting: true}) == Reconnecting,
  )
}

let run = () => {
  runTranscript()
  runNumbering()
  runTakeover()
  runNotPriced()
  runStop()
  runTimeout()
  runReplaySplit()
  runSendFailed()
  runConnectionState()
}
