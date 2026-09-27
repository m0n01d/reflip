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
