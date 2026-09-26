# reflip: profit estimate and profit readout

Status: lite spec, written 2026-09-26. It builds on M1 lite (`docs/spec-lite-m1.md`, [PR #2](https://github.com/m0n01d/reflip/pull/2)) and the budget spec (`docs/spec-budget.md`, [PR #18](https://github.com/m0n01d/reflip/pull/18)). Neither is merged yet. A separate session owns the redesign of the haul view. That session sets the layout, and this spec gives it the numbers.

## Problem

reflip shows a resale range for each find. It does not show what Dwight keeps after the eBay fee and the postage. On a $25 item in a 3 lb box, he keeps about $9, before the price that he paid. If an item in the smallest shipping class cost nothing, it still must sell for about $9.50 to break even.

When a find sells, nothing compares the result with the estimate. M1 lite compares the sold price with Claude's range. Nothing compares the profit, so an error in the postage or the fee stays hidden.

## Terms

- Midpoint: the average of the two ends of Claude's range.
- Net: a sale price, minus the eBay fee, minus the postage.
- Profit: the net minus the paid price.
- Shipping class: a size group that sets the postage of a find.
- Miss: the real profit minus the estimated profit.

## How it works

1. Scan. Claude gives each item a shipping class, next to its range. Code computes the net at the low end, the midpoint and the high end.
2. Look. The item sheet and the gem card show "Net $5 to $14". After Dwight types a paid price, they also show the profit.
3. Keep. The ledger row of each find stores the fee and the postage that code estimated at scan time. A later rate change does not change an old estimate.
4. Sell. Dwight records the sale in the Sold sheet of the budget spec: the sold price, the buyer shipping, the fees and the postage.
5. Learn. The profit readout compares each eBay sale with its estimate. It shows how far off the estimates are, and whether the price or the costs caused the miss.

All the math runs in code. Nothing new goes into a Claude request, except the `shipClass` field in the output schema.

## The math

Code assumes free shipping. The buyer pays the price plus sales tax, and Dwight pays for the label. Code assumes a sales tax of 7.5% on each order.

For a price `p` in Claude's range:

```
orderTotal = p × 1.075
fee        = 0.136 × orderTotal + (0.30 if orderTotal ≤ 10, else 0.40)
net        = p − fee − postage(shipClass)
profit     = net − paid
```

`ProfitTest.res` uses two cases. The first case is a range of $20 to $30, in class `medium` ($11.57), with a paid price of $4:

| | Low ($20) | Midpoint ($25) | High ($30) |
|---|---|---|---|
| Order total | 21.500 | 26.875 | 32.250 |
| Fee | 3.324 | 4.055 | 4.786 |
| Net | 5.106 | 9.375 | 13.644 |
| Profit | 1.106 | 5.375 | 9.644 |

The screen rounds to whole dollars: "Net $5 to $14" and "Profit $1 to $10".

The second case is an $8 item in class `small` ($7.69). The order total is 8.60, so the per-order fee is $0.30. The fee is 1.470 and the net is −1.160. The item loses money on eBay, even at a paid price of $0.

One fee rate covers all categories in this spec. eBay charges other rates in a few categories (see Facts and sources).

## Shipping classes

Claude picks one class for each item. It judges from the item and the box that the item needs. Code owns the dollar cost of each class, in `Profit.res`.

| Class | What it covers | Postage | Basis | Break-even price |
|---|---|---|---|---|
| `small` | Under 1 lb packed, in a mailer or a small box | $7.69 | Up to 15.999 oz | $9.48 |
| `medium` | 1 to 5 lb, in a box up to a 12-inch cube | $11.57 | 3 lb | $14.02 |
| `large` | 5 to 20 lb, or a box larger than a 12-inch cube | $16.76 | 10 lb | $20.10 |
| `pickup` | Over 20 lb, or too big or fragile to ship | $0 | Local sale | $0.35 |

The postage is the USPS Ground Advantage commercial price at zone 5, from Notice 123 of 2026-07-12. Zone 5 is a middle distance. Each postage is the price of a typical weight in its class, not the top weight. The break-even price is the lowest sale price that gives a net of $0.

The 12-inch cube is one cubic foot. Above that size, USPS charges a parcel by its size or its weight, whichever is more.

Distance changes the postage a lot. At zone 8, the first three classes cost $8.40, $15.75 and $25.34. At zone 1, they cost $6.93, $8.64 and $11.91.

A `pickup` find has no postage. Code still subtracts the eBay fee, because the estimate assumes an eBay sale.

Code uses classes, not weights. Claude can name a size group from a photo more reliably than a weight in ounces. Each class also gives the readout a group of sales to compare with its postage.

## Shape

- `Profit.res`: pure functions, the rate constants, and the date on which someone last read their sources. It follows `Pricing.res`, and it has no Node imports.
- `ProfitTest.res`: the two cases above, at a tolerance of $0.001.
- `SystemPrompt.res`: the schemas of the scene prompt and the haul prompt get a `shipClass` enum with the four values. The prompt describes each class in one line. The spot pass does not change.
- Decode: `Types.claudeItem` gets `shipClass`. If the value is missing or unknown, code uses `medium`.
- Reply: each item in `/api/scene`, each item event of `/api/scene/stream`, and each gem of `GET /api/hauls/:id` get a `profit` object. Its fields are `shipClass`, `postageUsd`, `feeMidUsd`, `netLowUsd`, `netMidUsd` and `netHighUsd`.
- Ledger: table `finds` gets `shipClass` (TEXT), `feeEstUsd` (REAL) and `postageEstUsd` (REAL). The fee is at the midpoint. `Store.openAt` adds the columns to an old database in place, as it does for `size`. Each path that writes a `finds` row also fills them.
- Haul email: each gem in `Digest.res` shows its net range.
- Readout: `GET /api/profit-readout`, plus a section in the Budget view, next to the calibration readout of M1 lite.

## The profit readout

If a find meets all of these conditions, the readout uses it:

- It has a sold price, and its channel is eBay.
- It has a stored estimate (`feeEstUsd` is set). Finds from before this spec have none.
- Its `fixture` flag is not set.

For each sale, code computes the values below. A positive miss means that Dwight made more than the estimate.

```
estimated = midpoint − feeEst − postageEst − paid
real      = sold + buyerShipping − fees − postage − paid
miss      = real − estimated
priceMiss = sold − midpoint
costMiss  = (feeEst + postageEst) − (fees + postage − buyerShipping)
```

`priceMiss` plus `costMiss` equals `miss`. The readout shows four lines:

1. The count of sales.
2. The estimated profit and the real profit, summed over the sales, and the difference. For example: "Estimated $212, made $180, $32 under."
3. The median price miss and the median cost miss per sale.
4. For each shipping class: the default postage, the median real postage, and the count of sales.

Dwight uses line 4 to set the postage of each class. If a class has fewer than 5 sales, line 4 shows only its count.

## Changes to the budget spec

The Sold sheet of the budget spec has one Fees field, for the eBay fee plus the postage. The readout needs the two apart, to tell a postage miss from a fee miss. This spec splits the field into Fees and Postage. The profit of the budget spec stays the same, because it subtracts both.

The Sold sheet fills in the eBay fee from the sold price and the buyer shipping, with no tax. It uses `Profit.res` for that fee instead, with the 7.5% tax. Both specs then use one fee formula.

## MVP

Do the steps in this order. Steps 1 to 3 do not need the budget spec.

1. Make sure that the eBay fee and the USPS prices are still current. Then write `Profit.res` and `ProfitTest.res`.
2. Add `shipClass` to the schema, the decode, the reply, the stream events and the ledger.
3. Show the net on the item sheet, on the gem card and in the haul email. Take the layout from the haul redesign.
4. After the budget spec builds its Sold sheet, add the readout: the route, a test with hand-made rows, and the view.
5. Run a smoke test with dev-browser at phone width. The test scans the fixture photo and reads the net on the item sheet and on a gem card. Then it types a paid price and reads the profit.

Only real sales can test the readout from end to end, because fixture finds never count.

## For the haul redesign

- Each item and each gem carries the `profit` object. The page computes no fee.
- One line under the range: "Net $5 to $14". With a paid price: "Profit $1 to $10".
- A tap on that line shows the parts at the midpoint: the price, the eBay fee, the postage with its class, and the paid price.
- A net below $0 is a loss. Show it in the warning style of the design.

## Later

- Category fee rates, after M1 lite adds its `category` field. The rates are in Facts and sources.
- Class postage from Dwight's own labels: after 5 sales in a class, use the median real postage.
- Buyer-paid shipping, as a choice next to free shipping.
- Exact postage by ZIP code from the USPS Domestic Prices 3.0 API. M1 lite lists it in Later too.
- The walk-away price of M1 lite: the net minus a minimum profit. `Profit.res` gives it with one more subtraction.
- The cost of boxes and mailers, and a promoted listing fee.

## Facts and sources

- eBay fee, read on [eBay help](https://www.ebay.com/help/selling/fees-credits-invoices/selling-fees?id=4822) with a fetch tool on 2026-09-25. It is 13.6% of the total up to $7,500, and 2.35% of the part above that. The per-order fee is $0.30 for an order of $10 or less, and $0.40 above $10. The total includes the item price, handling, the shipping that the buyer pays and the sales tax. The page gives no effective date. M1 lite read the same figures on 2026-09-24.
- Category rates on the same page: 15.3% for Books & Magazines, Movies & TV and Music. 6.7% for Guitars & Basses. 15% for Jewelry & Watches up to $5,000. 8% for Athletic Shoes at $150 or more, with no per-order fee. 13.25% for Sports Trading Cards.
- Fees that this spec leaves out: 6% more for a seller rated Below Standard, and 1.65% for an international sale.
- USPS [Notice 123](https://pe.usps.com/text/dmm300/Notice123.htm), effective 2026-07-12, table "Ground Advantage Commercial-Parcels". The prices below came from the HTML of the page on 2026-09-25. A fetch tool read the same values.

| Weight not over | Zone 1 | Zone 5 | Zone 8 |
|---|---|---|---|
| 15.999 oz | $6.93 | $7.69 | $8.40 |
| 3 lb | $8.64 | $11.57 | $15.75 |
| 10 lb | $11.91 | $16.76 | $25.34 |
| 20 lb | $16.46 | $24.93 | $40.39 |

- Not confirmed: the price of an eBay label. eBay's [Seller Center page](https://www.ebay.com/sellercenter/shipping/choosing-a-carrier-and-service/usps-and-ebay-labels) shows a calculator and no price table (read 2026-09-26). eBay Community posts say that eBay label prices for Ground Advantage changed on 2026-07-25 and on 2026-08-08. They also say that eBay keeps four weight tiers under 1 lb, but Notice 123 has one price for all of them. So a `small` label from eBay can cost less than $7.69. Before step 1, read one real eBay label price for each class.
- Sales tax: the [Tax Foundation](https://taxfoundation.org/data/all/state/2026-sales-tax-rates-midyear/) gives 7.53% for 2026. It is the average of state and local rates, weighted by population. This figure came from a search summary on 2026-09-25, not from the page. Code rounds it to 7.5%.

## Risks

- Free shipping is an assumption. If Dwight charges buyers for shipping, the cost miss shows it as a positive number near the buyer shipping.
- Zone 5 is a guess. Dwight's ZIP code decides the real mix of zones.
- Claude can pick the wrong class. A light item in a large box costs more than its weight suggests.
- The real tax rate changes with the address of the buyer.
- A few sales tell little. M1 lite gives the numbers: at 20 sales, the interval of its hit rate is still wide.
- Rates change. USPS prices changed on 2026-07-12, and eBay label prices changed twice after that. `Profit.res` keeps the date of its sources.
- The readout skips sales on Marketplace or for cash, because the estimate assumes an eBay sale.

## Open questions

1. What ZIP code does Dwight ship from? The answer sets the zone of the default postage.
2. Does Dwight offer free shipping, or do buyers pay for it?
3. Can the budget spec split its Fees field into Fees and Postage, and fill the fee from `Profit.res`?

## Non-goals

- A change to Claude's range. This spec reports the miss and does not correct it.
- An eBay API call that reflip does not make today.
- Sold prices, profits or the readout in a Claude request.
- Tag reading from the photo.
