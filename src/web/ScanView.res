// The styled run screen (docs/design/scan-ui/Main.dc.html — the Thinking,
// Searching, FirstFinds, Midway and Done boards) and the item sheet (the
// Item and EbayBlock boards). ScanShell.res owns the shared header and the
// Ready screen; this module owns everything once a scan has started.
//
// Pure view: every control here only ever calls `dispatch`. Stop and New
// scan's actual network-level effects (ScanApi.handle.stop/abort) run at
// the edge, in App.res, reacting to the model this produces — not here.
// `logOpen`/`alsoOpen` are local UI-only state (not folded into
// ScanState.model) so this pass adds no required field to a model built
// with `{...ScanState.initialModel, ...}` across the test suite.
//
// Self-contained on purpose (its own pct/crop helpers, no App.res
// helpers): App imports ScanShell, which imports this module, so importing
// back from App.res would be a circular dependency.

@send external toFixed: (float, int) => string = "toFixed"

// The design's fixed reference points (docs/scan-ui.md): a run stops at
// 3:00, and 0:47 is the median photo on 10 real scenes (reflip's own
// CLAUDE.md). Both are constants, not derived from any one run.
let limitMs = 180_000.0

let clampPct = (n: float): float => Math.max(0.0, Math.min(n, 100.0))

// A position along the track, or a pin's position on the photo: always a
// percentage of some known total, clamped and formatted once.
let pctOf = (part: float, total: float): string =>
  total <= 0.0 ? "0%" : toFixed(clampPct(part /. total *. 100.0), 2) ++ "%"

let boxCenterPct = (box: Types.box, sentWidth: int, sentHeight: int): (string, string) => (
  pctOf(Int.toFloat(box.x1 + box.x2) /. 2.0, Int.toFloat(sentWidth)),
  pctOf(Int.toFloat(box.y1 + box.y2) /. 2.0, Int.toFloat(sentHeight)),
)

let isGem = (item: Types.replyItem): bool => item.estimateHighUsd >= 20.0

let stickerName = (s: ScanState.sticker): string =>
  switch s.item {
  | Some(item) => item.name
  | None => s.name->Option.getOr("Item " ++ Int.toString(s.number))
  }

// -- Item sheet crop -----------------------------------------------------
// Ported from the design's own crop(b) (Main.dc.html): a window centered
// on the item's box, padded 30% a side, grown to the sheet's own aspect
// ratio, then clamped inside the photo — so the item always shows with
// room around it instead of edge to edge.
let sheetFrameW = 358.0
let sheetFrameH = 184.0

type cropGeometry = {
  imgWidthPx: float,
  imgLeftPx: float,
  imgTopPx: float,
  boxLeftPx: float,
  boxTopPx: float,
  boxWidthPx: float,
  boxHeightPx: float,
}

let cropOf = (box: Types.box, ~sentWidth: int, ~sentHeight: int): cropGeometry => {
  let sw = Int.toFloat(sentWidth)
  let sh = Int.toFloat(sentHeight)
  let bx1 = Int.toFloat(box.x1)
  let by1 = Int.toFloat(box.y1)
  let bx2 = Int.toFloat(box.x2)
  let by2 = Int.toFloat(box.y2)
  let bw = Math.max(bx2 -. bx1, 1.0)
  let bh = Math.max(by2 -. by1, 1.0)
  let cx = (bx1 +. bx2) /. 2.0
  let cy = (by1 +. by2) /. 2.0
  let aspect = sheetFrameW /. sheetFrameH
  let padW = bw *. 1.3
  let padH = bh *. 1.3
  let (winW, winH) = padW /. padH > aspect ? (padW, padW /. aspect) : (padH *. aspect, padH)
  let winW = Math.min(winW, sw)
  let winH = Math.min(winH, sh)
  let (winW, winH) = winW /. winH > aspect ? (winH *. aspect, winH) : (winW, winW /. aspect)
  let winW = Math.max(winW, 1.0)
  let winH = Math.max(winH, 1.0)
  let x1 = Math.max(0.0, Math.min(cx -. winW /. 2.0, sw -. winW))
  let y1 = Math.max(0.0, Math.min(cy -. winH /. 2.0, sh -. winH))
  let scale = sheetFrameW /. winW
  {
    imgWidthPx: sw *. scale,
    imgLeftPx: -.x1 *. scale,
    imgTopPx: -.y1 *. scale,
    boxLeftPx: (bx1 -. x1) *. scale,
    boxTopPx: (by1 -. y1) *. scale,
    boxWidthPx: bw *. scale,
    boxHeightPx: bh *. scale,
  }
}

let px = (n: float): string => toFixed(n, 1) ++ "px"

let chevron = (~className: string) =>
  <svg
    width="16"
    height="16"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="2"
    strokeLinecap="round"
    strokeLinejoin="round"
    ariaHidden={true}
    className>
    <path d="M6 9l6 6 6-6" />
  </svg>

@react.component
let make = (~model: ScanState.model, ~dispatch: ScanState.msg => unit, ~onNewPhoto: ReactEvent.Form.t => unit) => {
  let (logOpen, setLogOpen) = React.useState(() => false)
  let (alsoOpen, setAlsoOpen) = React.useState(() => false)
  let onSheetClose = (_: ReactEvent.Mouse.t) => dispatch(ScanState.SheetClosed)
  let onRetry = (_: ReactEvent.Mouse.t) => dispatch(ScanState.NewScan)
  let toggleLog = (_: ReactEvent.Mouse.t) => setLogOpen(o => !o)
  let toggleAlso = (_: ReactEvent.Mouse.t) => setAlsoOpen(o => !o)

  let visible = ScanState.visibleStickers(model)
  let latestNumber = Array.get(visible, Array.length(visible) - 1)->Option.map(s => s.number)
  let isLatest = (n: int) => latestNumber->Option.mapOr(false, l => l == n)
  let lines = ScanState.logLines(model)
  let lastLine = Array.get(lines, Array.length(lines) - 1)
  let marks = ScanState.trackMarks(model)
  let elapsed = ScanState.elapsedMs(model)
  let summary = ScanState.gemsSummary(model)
  let unpriced = visible->Array.filter(s => s.item->Option.isNone)
  let alsoItems = Array.concat(ScanState.others(model), unpriced)
  let sheetSticker =
    model.sheetOpen->Option.flatMap(n => model.stickers->Array.find(s => s.number == n))

  switch model.phase {
  | ScanState.Ready => React.null
  | ScanState.Sending | ScanState.Live | ScanState.Ended(_) =>
    <>
      <div className="scan-run">
        {switch model.photoUrl {
        | None => React.null
        | Some(url) =>
          <div className="scan-photo-frame">
            <img className="scan-photo-img" src={url} />
            {visible
            ->Array.filterMap(s =>
              switch s.box {
              | None => None
              | Some(box) =>
                let (left, top) = boxCenterPct(box, model.sentWidth, model.sentHeight)
                let latest = isLatest(s.number)
                let gem = s.item->Option.mapOr(false, isGem)
                Some(
                  <button
                    type_="button"
                    key={Int.toString(s.number)}
                    ariaLabel={"Item " ++ Int.toString(s.number)}
                    onClick={_ => dispatch(ScanState.SheetOpened(s.number))}
                    className={"scan-pin" ++ (latest ? " scan-pin-latest" : "")}
                    style={{JsxDOMStyle.left: left, top}}>
                    {gem
                      ? <span
                          className={"scan-pin-badge-gem" ++
                          (latest ? " scan-pin-badge-gem-top scan-pin-badge-latest" : "")}>
                          {React.string(Int.toString(s.number))}
                        </span>
                      : <span
                          className={"scan-pin-badge-plain" ++
                          (latest ? " scan-pin-badge-latest" : "")}
                        />}
                    {latest
                      ? switch s.item {
                        | Some(item) =>
                          <span className="scan-pin-callout">
                            {React.string(
                              ScanState.moneyRange(item.estimateLowUsd, item.estimateHighUsd),
                            )}
                          </span>
                        | None => React.null
                        }
                      : React.null}
                  </button>,
                )
              }
            )
            ->React.array}
          </div>
        }}
        <div className="scan-card-shadow">
          <div className="scan-card">
            <div className="scan-card-top-row">
              <h2 className="scan-headline"> {React.string(ScanState.headline(model))} </h2>
              <div className="scan-clock"> {React.string(ScanState.clock(model))} </div>
            </div>
            <p className="scan-sub"> {React.string(ScanState.sub(model))} </p>
            <div className="scan-track">
              <div className="scan-track-bg">
                <div
                  className="scan-track-fill" style={{JsxDOMStyle.width: pctOf(elapsed, limitMs)}}
                />
              </div>
              <div className="scan-track-usual-tick" />
              <div className="scan-track-usual-label"> {React.string("usual 0:47")} </div>
              <div className="scan-track-limit-label"> {React.string("3:00 limit")} </div>
              <div className="scan-track-thumb" style={{JsxDOMStyle.left: pctOf(elapsed, limitMs)}} />
              {marks
              ->Array.mapWithIndex((mark, i) => {
                let (cls, ms) = switch mark {
                | ScanState.SearchMark(t) => ("scan-track-mark-search", t)
                | ScanState.GemMark(t) => ("scan-track-mark-gem", t)
                | ScanState.PlainMark(t) => ("scan-track-mark-plain", t)
                }
                <div key={Int.toString(i)} className={cls} style={{JsxDOMStyle.left: pctOf(ms, limitMs)}} />
              })
              ->React.array}
            </div>
            {switch lastLine {
            | None => React.null
            | Some(line) =>
              <div className="scan-log-tail">
                <div className="scan-log-line scan-log-line-latest">
                  <span className="scan-log-time"> {React.string(line.time)} </span>
                  <span className="scan-log-text"> {React.string(line.text)} </span>
                  <span className="scan-log-right"> {React.string(line.right)} </span>
                </div>
              </div>
            }}
            {Array.length(lines) > 1
              ? <button type_="button" onClick={toggleLog} className="scan-log-toggle">
                  <span> {React.string(logOpen ? "Hide the log" : "Show the full log")} </span>
                  {chevron(
                    ~className="scan-log-toggle-chevron" ++
                    (logOpen ? " scan-log-toggle-chevron-open" : ""),
                  )}
                </button>
              : React.null}
            {logOpen
              ? <ul className="scan-log-full">
                  {lines
                  ->Array.mapWithIndex((line, i) =>
                    <li key={Int.toString(i)} className="scan-log-line">
                      <span className="scan-log-time"> {React.string(line.time)} </span>
                      <span className="scan-log-text"> {React.string(line.text)} </span>
                      <span className="scan-log-right"> {React.string(line.right)} </span>
                    </li>
                  )
                  ->React.array}
                </ul>
              : React.null}
            {ScanState.isEnded(model) && summary.count > 0
              ? <div className="scan-totals">
                  <div className="scan-totals-row">
                    <span> {React.string("worth a look")} </span>
                    <span>
                      {React.string(
                        Int.toString(summary.count) ++
                        " · " ++
                        ScanState.moneyRange(summary.sumLowUsd, summary.sumHighUsd),
                      )}
                    </span>
                  </div>
                </div>
              : React.null}
            {switch model.sceneReply {
            | Some({ebayNote: Some(note)}) =>
              <div className="scan-noebay">
                <span className="scan-noebay-icon" ariaHidden={true}> {React.string("⚠")} </span>
                <span>
                  <span className="scan-noebay-title"> {React.string("No eBay stats")} </span>
                  <span className="scan-noebay-note"> {React.string(note)} </span>
                </span>
              </div>
            | _ => React.null
            }}
            {switch model.phase {
            | ScanState.Ended(ScanEvent.EndStatus.Failed) =>
              <button type_="button" onClick={onRetry} className="scan-retry-btn">
                {React.string("Try again")}
              </button>
            | _ => React.null
            }}
            {ScanState.isEnded(model) && Array.length(visible) == 0
              ? <div className="scan-empty">
                  <div className="scan-empty-title"> {React.string("Nothing landed")} </div>
                  <div className="scan-empty-sub">
                    {React.string("Try moving closer, or add more light.")}
                  </div>
                </div>
              : React.null}
          </div>
        </div>
        {ScanState.isEnded(model) && summary.count > 0
          ? <div className="scan-gems">
              <div className="scan-section-head">
                <h3 className="scan-section-title"> {React.string("Worth a look")} </h3>
                <span className="scan-section-count"> {React.string(Int.toString(summary.count))} </span>
              </div>
              <div className="scan-section-sub">
                {React.string(ScanState.moneyRange(summary.sumLowUsd, summary.sumHighUsd))}
              </div>
              <div className="scan-rows-card">
                {summary.items
                ->Array.filterMap(s =>
                  switch s.item {
                  | None => None
                  | Some(item) =>
                    Some(
                      <button
                        type_="button"
                        key={Int.toString(s.number)}
                        onClick={_ => dispatch(ScanState.SheetOpened(s.number))}
                        className={"scan-gem-row" ++ (isLatest(s.number) ? " scan-gem-row-latest" : "")}>
                        <span className="scan-gem-badge"> {React.string(Int.toString(s.number))} </span>
                        <span className="scan-gem-name"> {React.string(item.name)} </span>
                        <span className="scan-gem-price-col">
                          <span className="scan-gem-price">
                            {React.string(ScanState.moneyRange(item.estimateLowUsd, item.estimateHighUsd))}
                          </span>
                          <span className="scan-gem-conf">
                            {React.string(ScanState.confidenceWord(item.confidence))}
                          </span>
                        </span>
                      </button>,
                    )
                  }
                )
                ->React.array}
              </div>
            </div>
          : React.null}
        {ScanState.isEnded(model) && Array.length(alsoItems) > 0
          ? <div className="scan-also">
              <button type_="button" onClick={toggleAlso} className="scan-also-toggle">
                <span className="scan-also-title-col">
                  <span className="scan-also-title">
                    {React.string("Also seen · " ++ Int.toString(Array.length(alsoItems)))}
                  </span>
                  {!alsoOpen
                    ? <span className="scan-also-preview">
                        {React.string(
                          alsoItems
                          ->Array.map(stickerName)
                          ->Array.reduce("", (acc, n) => acc == "" ? n : acc ++ ", " ++ n),
                        )}
                      </span>
                    : React.null}
                </span>
                {chevron(
                  ~className="scan-also-chevron" ++ (alsoOpen ? " scan-log-toggle-chevron-open" : ""),
                )}
              </button>
              {alsoOpen
                ? alsoItems
                  ->Array.map(s => {
                    let label = switch s.item {
                    | Some(item) => ScanState.moneyRange(item.estimateLowUsd, item.estimateHighUsd)
                    | None => ScanState.isNotPriced(model, s) ? "not priced" : ""
                    }
                    <button
                      type_="button"
                      key={Int.toString(s.number)}
                      onClick={_ => dispatch(ScanState.SheetOpened(s.number))}
                      className={"scan-also-row" ++ (isLatest(s.number) ? " scan-also-row-latest" : "")}>
                      <span className="scan-also-dot" />
                      <span className="scan-also-name"> {React.string(stickerName(s))} </span>
                      <span className="scan-also-price"> {React.string(label)} </span>
                    </button>
                  })
                  ->React.array
                : React.null}
            </div>
          : React.null}
        {ScanState.isEnded(model)
          ? switch ScanState.receipt(model) {
            | None => React.null
            | Some(r) =>
              <div className="scan-receipt">
                <div className="scan-receipt-label"> {React.string("RUN RECEIPT")} </div>
                <div className="scan-receipt-rows">
                  {[
                    ("model", r.modelLabel),
                    ("photo", r.photoSize),
                    ("claude", r.claude),
                    ("tokens", r.tokens),
                    ("web searches", Int.toString(r.webSearches)),
                    ("cost", r.cost),
                  ]
                  ->Array.map(((key, value)) =>
                    <div key={key} className="scan-receipt-row">
                      <span className="scan-receipt-key"> {React.string(key)} </span>
                      <span className="scan-receipt-dots" />
                      <span className="scan-receipt-val"> {React.string(value)} </span>
                    </div>
                  )
                  ->React.array}
                </div>
                <label className="scan-snap-another">
                  <input
                    type_="file"
                    accept="image/*"
                    capture=#environment
                    onChange={onNewPhoto}
                    className="scan-file-input"
                  />
                  {React.string("Snap another")}
                </label>
              </div>
            }
          : React.null}
      </div>
      {switch sheetSticker {
      | None => React.null
      | Some(sticker) =>
        <>
          <button
            type_="button"
            ariaLabel="Close"
            tabIndex={-1}
            onClick={onSheetClose}
            className="scan-sheet-backdrop"
          />
          <section role="dialog" ariaModal={true} ariaLabel="Item" className="scan-sheet-panel">
            <div className="scan-sheet-grabber-row">
              <span ariaHidden={true} className="scan-sheet-grabber" />
            </div>
            <div className="scan-sheet-content">
              <div className="scan-sheet-kicker-row">
                <span className="scan-sheet-kicker"> {React.string("#" ++ Int.toString(sticker.number))} </span>
                <button type_="button" ariaLabel="Close" onClick={onSheetClose} className="scan-sheet-close">
                  <svg
                    width="20"
                    height="20"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="2"
                    strokeLinecap="round"
                    ariaHidden={true}>
                    <path d="M6 6l12 12M18 6L6 18" />
                  </svg>
                </button>
              </div>
              {switch (sticker.box, model.photoUrl) {
              | (Some(box), Some(url)) =>
                let g = cropOf(box, ~sentWidth=model.sentWidth, ~sentHeight=model.sentHeight)
                <div className="scan-sheet-crop">
                  <img
                    className="scan-sheet-crop-img"
                    src={url}
                    style={{
                      JsxDOMStyle.width: px(g.imgWidthPx),
                      left: px(g.imgLeftPx),
                      top: px(g.imgTopPx),
                    }}
                  />
                  <div
                    className="scan-sheet-crop-box"
                    style={{
                      JsxDOMStyle.left: px(g.boxLeftPx),
                      top: px(g.boxTopPx),
                      width: px(g.boxWidthPx),
                      height: px(g.boxHeightPx),
                    }}
                  />
                </div>
              | _ => React.null
              }}
              <div className="scan-sheet-name-row">
                {switch sticker.item {
                | Some(item) if isGem(item) =>
                  <span className="scan-sheet-badge-gem"> {React.string(Int.toString(sticker.number))} </span>
                | Some(_) | None => <span className="scan-sheet-badge-plain" />
                }}
                <h2 className="scan-sheet-name"> {React.string(stickerName(sticker))} </h2>
              </div>
              {switch sticker.item {
              | Some(item) =>
                let filled = Float.toInt(Math.round(item.confidence *. 5.0))
                <>
                  <div className="scan-sheet-price-row">
                    <span className="scan-sheet-price">
                      {React.string(ScanState.moneyRange(item.estimateLowUsd, item.estimateHighUsd))}
                    </span>
                    <span className="scan-sheet-price-label"> {React.string("estimate")} </span>
                  </div>
                  <div className="scan-sheet-conf-row">
                    <span className="scan-sheet-dots">
                      {[0, 1, 2, 3, 4]
                      ->Array.map(i =>
                        <span
                          key={Int.toString(i)}
                          className={"scan-sheet-dot" ++ (i < filled ? " scan-sheet-dot-filled" : "")}
                        />
                      )
                      ->React.array}
                    </span>
                    <span className="scan-sheet-conf-word">
                      {React.string(ScanState.confidenceWord(item.confidence))}
                    </span>
                    <span className="scan-sheet-conf-num">
                      {React.string(Int.toString(Float.toInt(Math.round(item.confidence *. 100.0))) ++ "%")}
                    </span>
                  </div>
                  <p className="scan-sheet-basis"> {React.string(item.basis)} </p>
                  <div className="scan-ebay">
                    <div className="scan-ebay-top">
                      <span className="scan-ebay-label"> {React.string("EBAY")} </span>
                    </div>
                    {switch item.ebay {
                    | Some(stats) =>
                      <>
                        <div className="scan-ebay-title"> {React.string("Sold, last 90 days")} </div>
                        <div className="scan-ebay-stats">
                          <span>
                            {React.string(
                              "n=" ++
                              Int.toString(stats.count) ++
                              "  " ++
                              ScanState.usd0(stats.minUsd) ++
                              "–" ++
                              ScanState.usd0(stats.maxUsd),
                            )}
                          </span>
                          <span className="scan-ebay-median">
                            {React.string("median " ++ ScanState.usd0(stats.medianUsd))}
                          </span>
                        </div>
                      </>
                    | None =>
                      <div className="scan-ebay-note">
                        {React.string(
                          model.sceneReply
                          ->Option.flatMap(r => r.ebayNote)
                          ->Option.getOr("No eBay stats for this item."),
                        )}
                      </div>
                    }}
                    <div className="scan-ebay-searched-row">
                      <span className="scan-ebay-searched-label"> {React.string("searched")} </span>
                      <span className="scan-ebay-query"> {React.string(item.query)} </span>
                    </div>
                    <a
                      className="scan-ebay-sold-btn"
                      href={item.soldSearchUrl}
                      target="_blank"
                      rel="noreferrer">
                      {React.string("See sold listings ↗")}
                    </a>
                  </div>
                  {Array.length(item.sources) > 0
                    ? <div className="scan-sources">
                        <div className="scan-sources-label"> {React.string("SOURCES")} </div>
                        {item.sources
                        ->Array.mapWithIndex((src, i) =>
                          <span key={Int.toString(i)} className="scan-source-link">
                            {React.string(src)}
                          </span>
                        )
                        ->React.array}
                      </div>
                    : React.null}
                </>
              | None =>
                ScanState.isNotPriced(model, sticker)
                  ? <p className="scan-sheet-not-priced">
                      {React.string(stickerName(sticker) ++ " — not priced")}
                    </p>
                  : React.null
              }}
            </div>
          </section>
        </>
      }}
    </>
  }
}
