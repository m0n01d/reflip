// The streaming scan page (docs/scan-ui.md): a pure fold over ScanEvent.t
// plus a few UI msgs, and the pure functions the view derives from that
// model. ScanApi.res is the only thing that dispatches into this module —
// it owns the POST, the SSE read, Stop and reconnect. Nothing here reaches
// the network, the DOM, or a clock: the "elapsed" clock below ticks on the
// last event's own `t`, not on a live timer, because no `Tick` msg is in
// scope for this step (see the msg type).
//
// All `t: float` fields on ScanEvent.t are milliseconds, confirmed against
// ClaudeStream.res's `elapsedMs = () => Date.now() -. startMs` — not
// seconds like docs/design/scan-ui/Main.dc.html's simulated demo timeline.

// -- Stickers ---------------------------------------------------------------
//
// Sticker rules (docs/scan-ui.md, this track's brief): stickers number in
// landing order. The first box, spot-item or item to land gets 1. A `box`
// or `spot-item` lands a sticker with no estimate. The `item` with the same
// index fills its own sticker in. A priced item also takes over the spot
// sticker it overlaps at IoU >= 0.5 (Overlap.bestMatch): that spot sticker
// keeps its number and gains the item's data, and the item's own box-made
// sticker is marked `supersededBy` and never shown. A spot sticker with no
// match stays dim, and after `end` it shows "not priced" — call
// `ScanState.isNotPriced(model, sticker)`, not `sticker.item == None`
// alone, so a still-live scan doesn't jump the gun.
type sticker = {
  number: int, // 1-based, in landing order
  landedAtMs: float,
  box: option<Types.box>,
  name: option<string>, // a spot-item's name, until `item`/`scene` fills it in
  item: option<Types.replyItem>,
  supersededBy: option<int>, // Some(otherNumber) once superseded — never shown
}

type phase =
  | Ready
  | Sending
  | Live
  | Ended(ScanEvent.EndStatus.t)

type searchEntry = {
  id: string,
  query: option<string>,
  startedAtMs: float,
  result: option<result<int, string>>, // Ok(count) on search-done, Error(code) on search-failed
}

type doneInfo = {
  claudeMs: float,
  inputTokens: int,
  outputTokens: int,
  webSearches: int,
  usd: float,
}

type model = {
  phase: phase,
  selectedModel: Shared.model,
  photoUrl: option<string>,
  uploadBytes: int, // known client-side the moment a photo is picked
  sceneId: option<string>,
  sentWidth: int,
  sentHeight: int,
  lastEventAtMs: float,
  thinkingAtMs: option<float>,
  searches: array<searchEntry>,
  stickers: array<sticker>,
  // (wire index -> position in `stickers`), one slot per pass. A priced
  // item's own box always lands at `pricedSlot`; `spotSlot` is where a
  // takeover looks for a match to absorb into instead.
  pricedSlot: array<(int, int)>,
  spotSlot: array<(int, int)>,
  sceneReply: option<Types.sceneReply>,
  doneInfo: option<doneInfo>,
  endedAtMs: option<float>,
  errors: array<(float, string)>,
  stopRequested: bool, // StopTapped fired; waiting for the authoritative `end`
  reconnecting: bool,
  sheetOpen: option<int>, // the sticker number the item sheet is open for
}

let initialModel: model = {
  phase: Ready,
  selectedModel: Shared.defaultModel,
  photoUrl: None,
  uploadBytes: 0,
  sceneId: None,
  sentWidth: 0,
  sentHeight: 0,
  lastEventAtMs: 0.0,
  thinkingAtMs: None,
  searches: [],
  stickers: [],
  pricedSlot: [],
  spotSlot: [],
  sceneReply: None,
  doneInfo: None,
  endedAtMs: None,
  errors: [],
  stopRequested: false,
  reconnecting: false,
  sheetOpen: None,
}

type msg =
  | PhotoPicked({model: Shared.model, photoUrl: string, bytes: int})
  | GotEvent(result<ScanEvent.t, string>)
  | StopTapped
  | SheetOpened(int)
  | SheetClosed
  | ConnectionLost
  | Reconnected
  | NewScan
  // Bug A (288738f review): the first POST failed outright, or a
  // reconnect had no scene id to use — either way there is nothing left
  // to retry. Terminal, like an `Ended` from the server, but carries the
  // reason ScanApi could not hand it a real `ScanEvent.t` for.
  | SendFailed(string)

// -- The fold -----------------------------------------------------------

let findSlot = (slots: array<(int, int)>, key: int): option<int> =>
  slots->Array.find(((k, _)) => k == key)->Option.map(((_, pos)) => pos)

let setSticker = (stickers: array<sticker>, pos: int, f: sticker => sticker): array<sticker> =>
  stickers->Array.mapWithIndex((s, i) => i == pos ? f(s) : s)

// A raw box is only worth rescaling once the sent photo's real size is
// known (it arrives on `photo-received`, always the first event).
let toBox = (raw: array<int>, ~sentWidth: int, ~sentHeight: int, ~model: Shared.model): option<
  Types.box,
> =>
  sentWidth > 0 && sentHeight > 0
    ? Box.decode(Some(raw->Array.map(Int.toFloat)), ~sentWidth, ~sentHeight, ~model)
    : None

let tOf = (evt: ScanEvent.t): option<float> =>
  switch evt {
  | ScanEvent.PhotoReceived(_) | ScanEvent.Done(_) | ScanEvent.Scene(_) => None
  | ScanEvent.ClaudeStarted({t})
  | ScanEvent.Thinking({t})
  | ScanEvent.ToolRun({t})
  | ScanEvent.ToolDone({t})
  | ScanEvent.SearchStarted({t})
  | ScanEvent.SearchDone({t})
  | ScanEvent.SearchFailed({t})
  | ScanEvent.Box({t})
  | ScanEvent.Item({t})
  | ScanEvent.ErrorEvent({t})
  | ScanEvent.Stop({t})
  | ScanEvent.SpotStarted({t})
  | ScanEvent.SpotItem({t})
  | ScanEvent.SpotDone({t})
  | ScanEvent.SpotFailed({t})
  | ScanEvent.End({t}) => Some(t)
  }

let foldBox = (m: model, index: int, rawBox: array<int>, t: float): model => {
  let box = toBox(rawBox, ~sentWidth=m.sentWidth, ~sentHeight=m.sentHeight, ~model=m.selectedModel)
  switch findSlot(m.pricedSlot, index) {
  | Some(pos) => {...m, stickers: setSticker(m.stickers, pos, s => {...s, box})}
  | None => {
      let number = Array.length(m.stickers) + 1
      let sticker = {number, landedAtMs: t, box, name: None, item: None, supersededBy: None}
      {
        ...m,
        stickers: Array.concat(m.stickers, [sticker]),
        pricedSlot: Array.concat(m.pricedSlot, [(index, Array.length(m.stickers))]),
      }
    }
  }
}

// The spot pass's model is not yet fixed anywhere in the codebase (wave 2 /
// the brain branch is still in flight) — this assumes it matches the
// priced pass's model. Revisit once the brain names its own.
let foldSpotItem = (m: model, index: int, name: string, rawBox: array<int>, t: float): model => {
  let box = toBox(rawBox, ~sentWidth=m.sentWidth, ~sentHeight=m.sentHeight, ~model=m.selectedModel)
  switch findSlot(m.spotSlot, index) {
  | Some(pos) => {...m, stickers: setSticker(m.stickers, pos, s => {...s, box, name: Some(name)})}
  | None => {
      let number = Array.length(m.stickers) + 1
      let sticker = {number, landedAtMs: t, box, name: Some(name), item: None, supersededBy: None}
      {
        ...m,
        stickers: Array.concat(m.stickers, [sticker]),
        spotSlot: Array.concat(m.spotSlot, [(index, Array.length(m.stickers))]),
      }
    }
  }
}

let foldItem = (m: model, index: int, item: Types.replyItem, t: float): model => {
  let ownPos = findSlot(m.pricedSlot, index)
  // Candidates for a takeover: every spot-origin sticker with a box and no
  // item yet. `item.box` is always None on the wire today (StreamRoute's
  // toReplyItemPartial never sets it) — matching uses the box this same
  // index's own earlier `box` event already stored.
  let candidates =
    m.spotSlot->Array.filterMap(((_, pos)) =>
      switch Array.get(m.stickers, pos) {
      | Some({item: None, box: Some(b)}) => Some((pos, b))
      | _ => None
      }
    )
  let takeover = switch ownPos {
  | None => None
  | Some(pos) =>
    switch Array.get(m.stickers, pos) {
    | Some({box: Some(b)}) => Overlap.bestMatch(~box=b, ~candidates)
    | _ => None
    }
  }
  switch (ownPos, takeover) {
  | (Some(pos), Some(spotPos)) =>
    switch Array.get(m.stickers, spotPos) {
    | None => m // unreachable: spotPos came from m.stickers itself
    | Some(spotSticker) => {
        ...m,
        stickers: m.stickers
        ->setSticker(spotPos, s => {...s, item: Some(item)})
        ->setSticker(pos, s => {...s, supersededBy: Some(spotSticker.number)}),
      }
    }
  | (Some(pos), None) => {...m, stickers: setSticker(m.stickers, pos, s => {...s, item: Some(item)})}
  | (None, _) => {
      // Defensive: an `item` with no earlier `box` for its index. Give it
      // its own sticker instead of dropping the data.
      let number = Array.length(m.stickers) + 1
      let sticker = {
        number,
        landedAtMs: t,
        box: None,
        name: None,
        item: Some(item),
        supersededBy: None,
      }
      {
        ...m,
        stickers: Array.concat(m.stickers, [sticker]),
        pricedSlot: Array.concat(m.pricedSlot, [(index, Array.length(m.stickers))]),
      }
    }
  }
}

// A sticker position always equals number - 1: stickers are only ever
// appended, never reordered or removed.
let resolve = (stickers: array<sticker>, pos: int): int =>
  switch Array.get(stickers, pos) {
  | Some({supersededBy: Some(otherNumber)}) => otherNumber - 1
  | _ => pos
  }

let foldScene = (m: model, reply: Types.sceneReply): model => {
  let stickers = reply.items->Array.reduceWithIndex(m.stickers, (acc, item, index) =>
    switch findSlot(m.pricedSlot, index) {
    | Some(rawPos) =>
      let pos = resolve(acc, rawPos)
      acc->setSticker(pos, s => {
        ...s,
        item: Some(item),
        box: item.box->Option.isSome ? item.box : s.box,
      })
    | None => acc // this index never landed during the stream — leave as is
    }
  )
  {...m, sceneReply: Some(reply), stickers}
}

let foldEvent = (m: model, evt: ScanEvent.t): model => {
  let m = switch tOf(evt) {
  | Some(t) => {...m, lastEventAtMs: Math.max(m.lastEventAtMs, t)}
  | None => m
  }
  switch evt {
  | ScanEvent.PhotoReceived({sceneId, width, height}) =>
    {...m, sceneId: Some(sceneId), sentWidth: width, sentHeight: height, phase: Live}
  | ScanEvent.ClaudeStarted({t}) | ScanEvent.Thinking({t}) =>
    {...m, thinkingAtMs: m.thinkingAtMs->Option.isSome ? m.thinkingAtMs : Some(t)}
  | ScanEvent.ToolRun(_) | ScanEvent.ToolDone(_) => m // not shown — docs/scan-ui.md §4
  | ScanEvent.SearchStarted({t, id, query}) =>
    {...m, searches: Array.concat(m.searches, [{id, query, startedAtMs: t, result: None}])}
  | ScanEvent.SearchDone({id, count}) =>
    {
      ...m,
      searches: m.searches->Array.map(s => s.id == id ? {...s, result: Some(Ok(count))} : s),
    }
  | ScanEvent.SearchFailed({id, errorCode}) =>
    {
      ...m,
      searches: m.searches->Array.map(s =>
        s.id == id ? {...s, result: Some(Error(errorCode))} : s
      ),
    }
  | ScanEvent.Box({t, index, box}) => foldBox(m, index, box, t)
  | ScanEvent.Item({t, index, item}) => foldItem(m, index, item, t)
  | ScanEvent.Done({claudeMs, inputTokens, outputTokens, webSearches, usd}) =>
    {...m, doneInfo: Some({claudeMs, inputTokens, outputTokens, webSearches, usd})}
  | ScanEvent.Scene(reply) => foldScene(m, reply)
  | ScanEvent.ErrorEvent({t, message}) => {...m, errors: Array.concat(m.errors, [(t, message)])}
  | ScanEvent.Stop(_) => m // the client already knows it tapped Stop (stopRequested); the authoritative outcome is `end`
  | ScanEvent.SpotStarted(_) => m // no distinct headline moment for this in a plain view
  | ScanEvent.SpotItem({t, index, name, box}) => foldSpotItem(m, index, name, box, t)
  | ScanEvent.SpotDone(_) | ScanEvent.SpotFailed(_) => m // nothing derived shows these yet
  | ScanEvent.End({t, status}) => {...m, phase: Ended(status), endedAtMs: Some(t)}
  }
}

let update = (m: model, msg: msg): model =>
  switch msg {
  | PhotoPicked({model, photoUrl, bytes}) =>
    {...initialModel, phase: Sending, selectedModel: model, photoUrl: Some(photoUrl), uploadBytes: bytes}
  | GotEvent(Ok(evt)) => foldEvent(m, evt)
  | GotEvent(Error(_)) => m // a line ScanEvent.decode could not read; ScanApi.localEventCount is the one counter now (bug D, 288738f review)
  | SendFailed(reason) =>
    {
      ...m,
      phase: Ended(ScanEvent.EndStatus.Failed),
      endedAtMs: Some(m.lastEventAtMs),
      errors: Array.concat(m.errors, [(m.lastEventAtMs, reason)]),
    }
  | StopTapped => {...m, stopRequested: true}
  | SheetOpened(n) => {...m, sheetOpen: Some(n)}
  | SheetClosed => {...m, sheetOpen: None}
  | ConnectionLost => {...m, reconnecting: true}
  | Reconnected => {...m, reconnecting: false}
  | NewScan => initialModel
  }

// -- Pure derived functions for the view -------------------------------

let isEnded = (m: model): bool =>
  switch m.phase {
  | Ended(_) => true
  | _ => false
  }

// A sticker settles into "not priced" only once the scene has ended —
// before `end`, an unmatched spot sticker's estimate can still land, so
// the view keeps it dim instead of naming it unpriced. One tested
// function so both ScanView call sites share the same answer instead of
// duplicating the check.
let isNotPriced = (m: model, s: sticker): bool => s.item->Option.isNone && isEnded(m)

// The network edge's state, derived for display (docs/scan-ui.md; a
// later pass shows "Reconnecting" in the view). `reconnecting` already
// tracks a drop in progress; `Ended(Failed)` is the one phase where the
// network gave up, rather than the scan finishing on purpose (Stopped),
// on schedule (Done), or by the clock (Timeout).
type connectionState = Live | Reconnecting | Failed

let connectionState = (m: model): connectionState =>
  switch (m.reconnecting, m.phase) {
  | (true, _) => Reconnecting
  | (false, Ended(ScanEvent.EndStatus.Failed)) => Failed
  | (false, _) => Live
  }

let visibleStickers = (m: model): array<sticker> =>
  m.stickers->Array.filter(s => s.supersededBy->Option.isNone)

let plural = (n: int, one: string, many: string): string =>
  Int.toString(n) ++ " " ++ (n == 1 ? one : many)

let mss = (ms: float): string => {
  let totalSeconds = Float.toInt(Math.max(ms, 0.0) /. 1000.0)
  let m = totalSeconds / 60
  let s = mod(totalSeconds, 60)
  Int.toString(m) ++ ":" ++ (s < 10 ? "0" ++ Int.toString(s) : Int.toString(s))
}

let mb = (bytes: int): string => {
  let v = Math.round(Int.toFloat(bytes) /. 100_000.0) /. 10.0
  Float.toString(v)
}

let usd0 = (v: float): string => Int.toString(Float.toInt(Math.round(v)))

let moneyRange = (lo: float, hi: float): string => "$" ++ usd0(lo) ++ "–" ++ usd0(hi)

let confidenceWord = (c: float): string =>
  c >= 0.7 ? "confident" : c >= 0.4 ? "fair guess" : "rough guess"

let elapsedMs = (m: model): float =>
  switch m.endedAtMs {
  | Some(t) => Math.max(t, m.lastEventAtMs)
  | None => m.lastEventAtMs
  }

let clock = (m: model): string => mss(elapsedMs(m))

// "Worth a look": landed, priced, high estimate $20 or more. Sorted by low
// estimate then high estimate, both descending — landing order breaks a
// tie, for free, because Array.toSorted is a stable sort (same rank()
// order as docs/design/scan-ui/Main.dc.html).
let rank = (a: sticker, b: sticker): Ordering.t =>
  switch (a.item, b.item) {
  | (Some(ai), Some(bi)) =>
    ai.estimateLowUsd != bi.estimateLowUsd
      ? Float.compare(bi.estimateLowUsd, ai.estimateLowUsd)
      : Float.compare(bi.estimateHighUsd, ai.estimateHighUsd)
  | _ => 0.0
  }

let gems = (m: model): array<sticker> =>
  visibleStickers(m)
  ->Array.filter(s => s.item->Option.mapOr(false, i => i.estimateHighUsd >= 20.0))
  ->Array.toSorted(rank)

let others = (m: model): array<sticker> =>
  visibleStickers(m)
  ->Array.filter(s => s.item->Option.mapOr(false, i => i.estimateHighUsd < 20.0))
  ->Array.toSorted((a, b) => rank(a, b))

type gemsSummary = {items: array<sticker>, count: int, sumLowUsd: float, sumHighUsd: float}

let gemsSummary = (m: model): gemsSummary => {
  let items = gems(m)
  {
    items,
    count: Array.length(items),
    sumLowUsd: Array.reduce(items, 0.0, (acc, s) =>
      acc +. s.item->Option.mapOr(0.0, i => i.estimateLowUsd)
    ),
    sumHighUsd: Array.reduce(items, 0.0, (acc, s) =>
      acc +. s.item->Option.mapOr(0.0, i => i.estimateHighUsd)
    ),
  }
}

let headline = (m: model): string =>
  switch m.phase {
  | Ready => "Ready"
  | Sending => "Sending photo"
  | Ended(ScanEvent.EndStatus.Done) => {
      let n = Array.length(gems(m))
      n > 0 ? Int.toString(n) ++ " worth a look" : "Nothing over $20"
    }
  | Ended(ScanEvent.EndStatus.Timeout) => "Stopped at 3:00"
  | Ended(ScanEvent.EndStatus.Stopped) => "Stopped"
  | Ended(ScanEvent.EndStatus.Failed) => "Could not finish"
  | Live =>
    if m.stopRequested {
      "Stopping"
    } else {
      let n = Array.length(visibleStickers(m))
      if n > 0 {
        Int.toString(n) ++ " found so far"
      } else {
        let anySearchDone = Array.some(m.searches, s => s.result->Option.isSome)
        let anySearchActive = Array.some(m.searches, s => s.result->Option.isNone)
        if anySearchDone && !anySearchActive {
          "Writing up items"
        } else if anySearchActive || Array.length(m.searches) > 0 {
          "Looking up prices"
        } else if m.thinkingAtMs->Option.isSome {
          "Looking it over"
        } else {
          "Sending photo"
        }
      }
    }
  }

let sub = (m: model): string =>
  switch m.phase {
  | Ready => "Take a photo of the table."
  | Sending => "Uploading " ++ mb(m.uploadBytes) ++ " MB."
  | Ended(ScanEvent.EndStatus.Done) => plural(Array.length(visibleStickers(m)), "item", "items") ++ " on the table"
  | Ended(ScanEvent.EndStatus.Timeout) =>
    "Hit the time limit. Kept the " ++
    plural(Array.length(visibleStickers(m)), "item", "items") ++ " found before it."
  | Ended(ScanEvent.EndStatus.Stopped) => {
      let n = Array.length(visibleStickers(m))
      n > 0 ? "Kept the " ++ plural(n, "item", "items") ++ " found so far." : "Nothing had landed yet."
    }
  | Ended(ScanEvent.EndStatus.Failed) => "Something went wrong. Kept what it found."
  | Live =>
    if m.stopRequested {
      "Finishing up the items already found."
    } else {
      let n = Array.length(visibleStickers(m))
      if n > 0 {
        let g = Array.length(gems(m))
        g > 0 ? Int.toString(g) ++ " worth a look so far" : "None over $20 yet"
      } else {
        let anySearchDone = Array.some(m.searches, s => s.result->Option.isSome)
        let anySearchActive = Array.some(m.searches, s => s.result->Option.isNone)
        if anySearchDone && !anySearchActive {
          "The first items land in a few seconds."
        } else if anySearchActive || Array.length(m.searches) > 0 {
          "Checking the web for what these sell for."
        } else if m.thinkingAtMs->Option.isSome {
          "Most photos take about 0:47."
        } else {
          "Sending the photo to Claude."
        }
      }
    }
  }

type logLine = {time: string, text: string, right: string}

// Built from the searches and stickers already folded in, not from a raw
// event log (this model keeps none). Each row keeps its raw millisecond
// time until the final sort, then only formats to mm:ss for display —
// sorting on the "mm:ss" string directly would put "10:05" before "9:03".
let logLines = (m: model): array<logLine> => {
  let searchRows = m.searches->Array.map(s => {
    let label = s.query->Option.mapOr("a search", q => "\"" ++ q ++ "\"")
    let (text, right) = switch s.result {
    | None => ("Searching " ++ label, "")
    | Some(Ok(count)) => ("Searched " ++ label, plural(count, "result", "results"))
    | Some(Error(_)) => ("Searched " ++ label, "no results")
    }
    (s.startedAtMs, text, right)
  })
  let itemRows =
    visibleStickers(m)->Array.filterMap(s =>
      switch s.item {
      | Some(item) =>
        Some((
          s.landedAtMs,
          "#" ++ Int.toString(s.number) ++ " " ++ item.name,
          moneyRange(item.estimateLowUsd, item.estimateHighUsd),
        ))
      | None => None
      }
    )
  let endRows = switch (m.phase, m.endedAtMs) {
  | (Ended(status), Some(t)) => [
      (
        t,
        switch status {
        | ScanEvent.EndStatus.Done => "Done"
        | ScanEvent.EndStatus.Stopped => "Stopped by you"
        | ScanEvent.EndStatus.Timeout => "Hit the 3:00 limit"
        | ScanEvent.EndStatus.Failed => "Could not finish"
        },
        "",
      ),
    ]
  | _ => []
  }
  Array.concat(Array.concat(searchRows, itemRows), endRows)
  ->Array.toSorted(((t1, _, _), (t2, _, _)) => Float.compare(t1, t2))
  ->Array.map(((t, text, right)) => {time: mss(t), text, right})
}

// -- Track marks ----------------------------------------------------------
// A dot per search, a tick per landed item (gem or plain), along the
// elapsed timeline — docs/design/scan-ui/Main.dc.html's track strip.
type trackMark =
  | SearchMark(float)
  | GemMark(float)
  | PlainMark(float)

let trackMarkAtMs = (mark: trackMark): float =>
  switch mark {
  | SearchMark(t) | GemMark(t) | PlainMark(t) => t
  }

let trackMarks = (m: model): array<trackMark> => {
  let searchMarks = m.searches->Array.map(s => SearchMark(s.startedAtMs))
  let itemMarks = visibleStickers(m)->Array.filterMap(s =>
    switch s.item {
    | Some(item) =>
      Some(item.estimateHighUsd >= 20.0 ? GemMark(s.landedAtMs) : PlainMark(s.landedAtMs))
    | None => None
    }
  )
  Array.concat(searchMarks, itemMarks)->Array.toSorted((a, b) =>
    Float.compare(trackMarkAtMs(a), trackMarkAtMs(b))
  )
}

// -- Run receipt ------------------------------------------------------------
// Only what the wire contract actually carries: no resize or round-trip
// time (docs/scan-ui.md's event table has no field for either — see this
// track's report for why they are left out of a "plain working view").
type receipt = {
  modelLabel: string,
  photoSize: string,
  claude: string,
  tokens: string,
  webSearches: int,
  cost: string,
}

let receipt = (m: model): option<receipt> =>
  m.doneInfo->Option.map(d => {
    modelLabel: Shared.modelLabel(m.selectedModel),
    photoSize: Int.toString(m.sentWidth) ++ " x " ++ Int.toString(m.sentHeight),
    claude: mss(d.claudeMs),
    tokens: Int.toString(d.inputTokens) ++ " in, " ++ Int.toString(d.outputTokens) ++ " out",
    webSearches: d.webSearches,
    cost: "$" ++ Float.toString(Math.round(d.usd *. 10000.0) /. 10000.0),
  })
