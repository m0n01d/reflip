// A plain working view for the streaming scan flow (docs/scan-ui.md §4):
// the photo with its stickers, the headline/sub/clock, the activity log,
// Stop, New scan, and an item sheet. No design polish — a later agent
// styles this against docs/shots/design/*.png. Every part below carries a
// class name that names its design part, for that pass to hook onto.
//
// Pure view: every control here only ever calls `dispatch`. Stop and New
// scan's actual network-level effects (ScanApi.handle.stop/abort) run at
// the edge, in App.res, reacting to the model this produces — not here.
//
// Self-contained on purpose (its own toFixed/pct, no App.res helpers): App
// will import this module to render it, so importing back from App.res
// would be a circular dependency.

@send external toFixed: (float, int) => string = "toFixed"

let pct = (n: int, total: int): string =>
  total <= 0 ? "0%" : toFixed(Int.toFloat(n) /. Int.toFloat(total) *. 100.0, 2) ++ "%"

@react.component
let make = (~model: ScanState.model, ~dispatch: ScanState.msg => unit) => {
  let onSheetClose = (_: ReactEvent.Mouse.t) => dispatch(ScanState.SheetClosed)
  let onStop = (_: ReactEvent.Mouse.t) => dispatch(ScanState.StopTapped)
  let onNewScan = (_: ReactEvent.Mouse.t) => dispatch(ScanState.NewScan)

  let showStop = switch model.phase {
  | Sending | Live => true
  | Ready | Ended(_) => false
  }

  let sheetSticker =
    model.sheetOpen->Option.flatMap(n => model.stickers->Array.find(s => s.number == n))

  <div className="scan">
    <div className="scan-header">
      {showStop
        ? <button className="scan-stop" onClick={onStop}> {React.string("Stop")} </button>
        : React.null}
      {ScanState.isEnded(model)
        ? <button className="scan-new-scan" onClick={onNewScan}>
            {React.string("New scan")}
          </button>
        : React.null}
    </div>
    {switch model.photoUrl {
    | None => React.null
    | Some(url) =>
      <div className="scan-photo">
        <img className="scan-photo-img" src={url} />
        {ScanState.visibleStickers(model)
        ->Array.filterMap(s =>
          switch s.box {
          | None => None
          | Some(box) =>
            Some(
              <div
                key={Int.toString(s.number)}
                className={"scan-sticker" ++
                (s.item->Option.isSome ? " scan-sticker-priced" : " scan-sticker-dim")}
                style={{
                  JsxDOMStyle.left: pct(box.x1, model.sentWidth),
                  top: pct(box.y1, model.sentHeight),
                }}
                onClick={_ => dispatch(ScanState.SheetOpened(s.number))}>
                {React.string(Int.toString(s.number))}
              </div>,
            )
          }
        )
        ->React.array}
      </div>
    }}
    <div className="scan-headline-row">
      <div className="scan-headline"> {React.string(ScanState.headline(model))} </div>
      <div className="scan-clock"> {React.string(ScanState.clock(model))} </div>
    </div>
    <div className="scan-sub"> {React.string(ScanState.sub(model))} </div>
    <ul className="scan-log">
      {ScanState.logLines(model)
      ->Array.mapWithIndex((line, i) =>
        <li key={Int.toString(i)} className="scan-log-line">
          <span className="scan-log-time"> {React.string(line.time)} </span>
          <span className="scan-log-text"> {React.string(line.text)} </span>
          <span className="scan-log-right"> {React.string(line.right)} </span>
        </li>
      )
      ->React.array}
    </ul>
    {switch sheetSticker {
    | None => React.null
    | Some(sticker) =>
      <div className="scan-sheet">
        <div className="scan-sheet-backdrop" onClick={onSheetClose} />
        <div className="scan-sheet-content">
          <button className="scan-sheet-close" onClick={onSheetClose}>
            {React.string("Close")}
          </button>
          {switch sticker.item {
          | Some(item) =>
            <>
              <div className="scan-sheet-name"> {React.string(item.name)} </div>
              <div className="scan-sheet-range">
                {React.string(ScanState.moneyRange(item.estimateLowUsd, item.estimateHighUsd))}
              </div>
              <div className="scan-sheet-confidence">
                {React.string(ScanState.confidenceWord(item.confidence))}
              </div>
              <div className="scan-sheet-basis"> {React.string(item.basis)} </div>
              <div className="scan-sheet-ebay">
                {switch item.ebay {
                | Some(stats) =>
                  React.string(
                    "eBay n=" ++
                    Int.toString(stats.count) ++
                    "  " ++
                    ScanState.usd0(stats.minUsd) ++
                    "-" ++
                    ScanState.usd0(stats.maxUsd) ++
                    " (median " ++
                    ScanState.usd0(stats.medianUsd) ++ ")",
                  )
                | None => React.string("no eBay stats")
                }}
              </div>
              <a
                className="scan-sheet-sold"
                href={item.soldSearchUrl}
                target="_blank"
                rel="noreferrer">
                {React.string("Sold listings")}
              </a>
            </>
          | None =>
            <div className="scan-sheet-name">
              {React.string(
                sticker.name->Option.getOr("Item " ++ Int.toString(sticker.number)) ++
                " — not priced",
              )}
            </div>
          }}
        </div>
      </div>
    }}
  </div>
}
