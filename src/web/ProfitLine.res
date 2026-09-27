// The profit line under the price range on a scan item sheet
// (ScanView.res) and on an open haul gem card (App.res GemCard)
// (docs/spec-profit.md "For the haul redesign"). Profit.res holds every
// money text and the loss rule; this view only wires it to a <details>
// disclosure.
//
// The open/closed state lives in the <details> DOM node itself, like
// focus or scroll — it needs no msg and no model field. The caller passes
// a `key` tied to the item's own identity, so React remounts a fresh,
// closed <details> when the sheet shows a different item.
@react.component
let make = (~profit: option<Profit.estimate>, ~lowUsd: float, ~highUsd: float) =>
  switch profit {
  | None => React.null
  | Some(e) =>
    let midUsd = (lowUsd +. highUsd) /. 2.0
    <details className={Profit.isLoss(e) ? "profit profit-loss" : "profit"}>
      <summary> {React.string(Profit.lineText(e))} </summary>
      <div className="profit-parts"> {React.string(Profit.partsText(e, ~midUsd))} </div>
    </details>
  }
