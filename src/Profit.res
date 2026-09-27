// The eBay fee, the USPS postage and the net of a sale, per
// docs/spec-profit.md, "The math" and "Shipping classes". Pure, no Node
// imports, modeled on Pricing.res.

type shipClass = Small | Medium | Large | Pickup

let toString = (c: shipClass): string =>
  switch c {
  | Small => "small"
  | Medium => "medium"
  | Large => "large"
  | Pickup => "pickup"
  }

let fromString = (s: string): option<shipClass> =>
  switch s {
  | "small" => Some(Small)
  | "medium" => Some(Medium)
  | "large" => Some(Large)
  | "pickup" => Some(Pickup)
  | _ => None
  }

// Claude can omit shipClass on an item; code then assumes medium
// (docs/spec-profit.md "Decode").
let defaultClass = Medium

// Sales tax on the buyer's order. Source: the Tax Foundation, 2026 state and
// local average, read 2026-09-25 (docs/spec-profit.md, Facts and sources).
let taxRate = 0.075

// The eBay fee rate on the order total, plus its flat per-order add-on.
// Source: eBay help, read 2026-09-25 (docs/spec-profit.md, Facts and
// sources).
let feeRate = 0.136
let feeFlatLowUsd = 0.30
let feeFlatHighUsd = 0.40
let feeFlatThresholdUsd = 10.0

// USPS Ground Advantage commercial postage, at zone 5. Source: USPS Notice
// 123, prices of 2026-07-12 (docs/spec-profit.md, Shipping classes).
let postageSmallUsd = 7.69
let postageMediumUsd = 11.57
let postageLargeUsd = 16.76
let postagePickupUsd = 0.0

// The date these rates were last read. Do not re-check them; they are one
// day old.
let sourcesReadOn = "2026-09-26"

let postage = (c: shipClass): float =>
  switch c {
  | Small => postageSmallUsd
  | Medium => postageMediumUsd
  | Large => postageLargeUsd
  | Pickup => postagePickupUsd
  }

// orderTotal = price x 1.075. fee = 0.136 x orderTotal, plus 0.30 at or
// under $10, else 0.40.
let fee = (price: float): float => {
  let orderTotal = price *. (1.0 +. taxRate)
  let flat = orderTotal <= feeFlatThresholdUsd ? feeFlatLowUsd : feeFlatHighUsd
  feeRate *. orderTotal +. flat
}

let net = (price: float, c: shipClass): float => price -. fee(price) -. postage(c)

type estimate = {
  shipClass: shipClass,
  postageUsd: float,
  feeMidUsd: float,
  netLowUsd: float,
  netMidUsd: float,
  netHighUsd: float,
  tagPriceUsd: option<float>,
}

let estimate = (
  ~lowUsd: float,
  ~highUsd: float,
  ~shipClass: shipClass,
  ~tagPriceUsd: option<float>,
): estimate => {
  let midUsd = (lowUsd +. highUsd) /. 2.0
  {
    shipClass,
    postageUsd: postage(shipClass),
    feeMidUsd: fee(midUsd),
    netLowUsd: net(lowUsd, shipClass),
    netMidUsd: net(midUsd, shipClass),
    netHighUsd: net(highUsd, shipClass),
    tagPriceUsd,
  }
}

// Whole-dollar money text, in the style of ScanState.usd0 (Math.round,
// Float.toInt, Int.toString) but with the sign outside the "$" — "-$1", not
// "$-1" (docs/spec-profit.md, netText: "A negative value shows as \"-$1\"").
// Profit.res stays Node-free, so it does not import the web-only
// ScanState.res; this is a small helper of its own, in the same shape.
let usd0 = (v: float): string => {
  let n = Float.toInt(Math.round(v))
  n < 0 ? "-$" ++ Int.toString(-n) : "$" ++ Int.toString(n)
}

// Two-decimal money text. Only ever called on a fee or a postage, which are
// never negative, so no sign handling is needed here.
let usdCents = (v: float): string => "$" ++ Float.toFixed(v, ~digits=2)

// "$5 to $14", or just "$5" when both ends round to the same whole dollar.
let rangeText = (loUsd: float, hiUsd: float): string => {
  let lo = usd0(loUsd)
  let hi = usd0(hiUsd)
  lo == hi ? lo : lo ++ " to " ++ hi
}

// A tag price shows cents only when it is not whole: "$4", but "$0.50" and
// "$2.50" (docs/spec-profit.md, "For the haul redesign").
let tagText = (v: float): string =>
  Math.abs(v -. Math.round(v)) < 0.005 ? usd0(v) : usdCents(v)

// "Net $5 to $14" — the net at the low end and the high end, in whole
// dollars (docs/spec-profit.md, "For the haul redesign").
let netText = (e: estimate): string => "Net " ++ rangeText(e.netLowUsd, e.netHighUsd)

// With a tag price: Some("Profit $1 to $10 at the $4 tag") — profit is the
// net minus the tag, at each end. Without one, None.
let profitText = (e: estimate): option<string> =>
  switch e.tagPriceUsd {
  | None => None
  | Some(tag) =>
    Some(
      "Profit " ++
      rangeText(e.netLowUsd -. tag, e.netHighUsd -. tag) ++
      " at the " ++
      tagText(tag) ++
      " tag",
    )
  }

// profitText when there is a tag price, else netText — the one line a gem
// card or the haul email shows under the range.
let lineText = (e: estimate): string =>
  switch profitText(e) {
  | Some(t) => t
  | None => netText(e)
  }

// With a tag price, the item loses money if the midpoint net, less the tag,
// is under $0. Without one, if the midpoint net alone is under $0.
let isLoss = (e: estimate): bool =>
  switch e.tagPriceUsd {
  | Some(tag) => e.netMidUsd -. tag < 0.0
  | None => e.netMidUsd < 0.0
  }

// The parts at the midpoint: "Price $25 · eBay fee $4.06 · Postage $11.57
// (medium)", plus " · Tag $4" when there is a tag price. midUsd is the
// midpoint of the scan range — estimate itself keeps no raw price, only the
// net and the fee derived from it, so the caller passes it in.
let partsText = (e: estimate, ~midUsd: float): string => {
  let base =
    "Price " ++
    usd0(midUsd) ++
    " · eBay fee " ++
    usdCents(e.feeMidUsd) ++
    " · Postage " ++
    usdCents(e.postageUsd) ++
    " (" ++
    toString(e.shipClass) ++
    ")"
  switch e.tagPriceUsd {
  | Some(tag) => base ++ " · Tag " ++ tagText(tag)
  | None => base
  }
}
