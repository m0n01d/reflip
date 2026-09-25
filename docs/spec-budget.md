# reflip budget: a monthly buy limit, and what each buy made

Status: proposal, written 2026-09-25. It builds on the paid and sold entry of M1 lite (`docs/spec-lite-m1.md`, on [PR #2](https://github.com/m0n01d/reflip/pull/2), not merged yet). The haul map (`docs/spec-haul-map.md`) puts the buys of this spec on a map.

## Problem

Dwight buys items at yard sales and thrift stores, and resells them. He wants a limit on what he spends each month, for example $1,000. He also wants to change that limit at any time. He also wants to record what each item sold for, and to see his spend and his profit for each month in charts.

Today reflip values items, but it records no money. The `finds` table has the columns `paidUsd`, `soldUsd`, `soldOn` and `soldWhere` for M1 lite. No route and no view writes them yet.

## Terms

- Find: one item from one scene, as in M1 lite.
- Buy: a find with a paid price, or a manual buy.
- Manual buy: a buy that Dwight types, with no find. An example is an item that no photo shows.
- Spend: the sum of the paid prices in one calendar month.
- Buy limit: the most spend that Dwight wants in one month.
- Left: the buy limit minus the spend. If the spend is over the buy limit, left is negative.
- On hand: the buys that have no sale yet.
- Channel: where an item sold: eBay, Marketplace, cash or other.
- Profit: the sold price, minus the paid price, minus the fees.
- Haul budget: the existing cap on the Claude cost of one haul, `HAUL_MAX_USD`. It is not part of this feature (see Decisions).

## How it works

1. Set the buy limit. In the Budget view, Dwight types an amount, for example $1,000. He can change it at any time. A change applies to the current month and to each month after it. Each earlier month keeps its own buy limit.
2. Buy. At a sale, Dwight taps Bought on a gem card in the haul view and types the price. The sheet shows what is left of the month after this buy. For an item with no gem card, he uses Add a buy in the Budget view.
3. Sell. Later, Dwight opens the On hand list in the Budget view and taps the buy. He types the sold price, the date, the channel and the fees.
4. Track. The Budget view shows the spend, what is left, the sales, the profit and the on-hand total for a month. Three charts show the pace of the month and the last 12 months.

reflip never blocks a buy. When the spend goes over the buy limit, the view shows how far over it is.

The haul view shows one more line under the counts, for example "September: $640 of $1,000 spent". With no buy limit, the line is "September: $640 spent". Dwight then knows what is left before he buys.

## Money and dates

- Prices are US dollars and cents. The page accepts "12", "12.5", "$12.50" and "1,200". It refuses a negative price, and a price over $100,000.
- The store keeps dollars in REAL columns, as `costUsd` does. `Budget.res` rounds each amount to whole cents before it adds, so a sum has no float error.
- A date is a local date, `YYYY-MM-DD`, from the clock of the phone. A month is `YYYY-MM`. The brain does no time-zone math for money.
- A buy counts in the month of its paid date, `paidOn`. A sale counts in the month of its sold date, `soldOn`. Thus a September buy that sells in November adds to the spend of September and to the profit of November.
- By default, the paid date of a find is the local date of its scan. Dwight buys at the sale where he took the photo. He can change the date in the sheet.
- The paid date of a manual buy and the sold date of a sale are today by default.
- A free item is a buy of $0. A sale needs a buy first.

## Fees

The Sold sheet has a Fees field for the marketplace fee plus the postage that Dwight paid. The field is optional, and $0 by default. When Dwight picks eBay as the channel, the sheet fills in the eBay fee. Dwight can change the value.

The eBay fee is 13.6% of the sold price, plus $0.30 for a sale of $10 or less, or $0.40 above $10. M1 lite read these figures on 2026-09-24. eBay charges the fee on the total with shipping and tax. If the buyer pays for shipping, the filled value is too low. Before the build, make sure that the fee figures are current.

The channel goes in the existing `soldWhere` column, as `ebay`, `marketplace`, `cash` or `other`.

## The Budget view

From the top down:

- A month picker. It opens on the current month.
- Tiles for the spend and the buy limit ("$640 of $1,000"), and for what is left ("$360 left" or "$45 over"). More tiles show the sales, the profit, and on hand (a count and the paid total).
- Chart 1, the pace of the month. A line shows the running total of the spend, day by day. A flat line marks the buy limit. A dashed line goes from $0 on day 1 to the buy limit on the last day, and marks an even pace. In the current month, the running total stops at today.
- Chart 2, the spend by month. It has one bar for each of the last 12 months. A short line across each bar marks the buy limit of that month. A bar over its buy limit gets the warning color.
- Chart 3, the profit by month. It has one bar for each of the last 12 months, up from zero for a profit and down for a loss.
- The buys of the month, newest first. Each row shows the name, the paid price and the date. A sold buy also shows its sale.
- On hand: each buy with no sale, oldest first, with the days since the buy. A tap opens the Sold sheet.
- Add a buy. Dwight picks a gem from the last 14 days that has no paid price, or types a name. Then he types the price and the date. If a haul is active, the form links the buy to it, so the buy shows on the haul map.

If Dwight has no buy limit yet, the view shows the spend and the charts with no buy-limit line. It also shows a Set limit form with $1,000 in it, the figure that Dwight used as an example.

The Budget view replaces the Finds view that M1 lite proposes. The calibration readout of M1 lite can go into this view later.

## Shape

The brain:

- Table `finds` gets two columns: `paidOn` (TEXT) and `feesUsd` (REAL). `Store.openAt` adds them to an old database in place, as it does for `size` and the box columns.
- New table `manualBuys`, with one row for each manual buy. Its own columns are `buyId` (TEXT PRIMARY KEY, from `crypto.randomUUID`), `name`, `haulId`, `note` and `createdAt`. For a buy with no haul, `haulId` is null. Its money columns match `finds`: `paidUsd`, `paidOn`, `soldUsd`, `soldOn`, `soldWhere` and `feesUsd`.
- New table `buyLimits`: `month` (TEXT PRIMARY KEY, `YYYY-MM`), `limitUsd` (REAL) and `setAt` (TEXT). The buy limit of a month comes from the row with the latest `month` that is not after it. A change writes the row of the current month.
- `Money.res`: the price parse, the rounding to cents and the dollar format. It has no Node imports, so the brain and the page share it, as they share `Shared.res`.
- `Budget.res`: pure functions from the rows to one month. They give the figures of the month: spend, left, sales, fees, profit and on hand. They also give the running total for each day, and the 12-month series.
- `MoneyTest.res` and `BudgetTest.res`: hand-computed values, as `PricingTest.res` has. The cases include a buy on the last day of a month, and a month before the first `buyLimits` row. They also include a buy-limit change inside the 12 months, a sale at a loss, and February 2028 (29 days).

The routes:

- `POST /api/finds/:id/paid` with `{"paidUsd": 12, "paidOn": "2026-09-25"}`. This is the M1 lite route, plus `paidOn`. A `paidUsd` of null clears the buy and its sale.
- `POST /api/finds/:id/sold` with `{"soldUsd": 40, "soldOn": "2026-10-02", "soldWhere": "ebay", "feesUsd": 5.84}`. This is the M1 lite route, plus `feesUsd`. A `soldUsd` of null clears the sale.
- `GET /api/finds?days=14` lists the finds of the last 14 days, for Add a buy. This is the M1 lite route, plus a filter.
- `POST /api/manual-buys` makes a manual buy and returns its `buyId`. `POST /api/manual-buys/:id/paid` and `POST /api/manual-buys/:id/sold` take the same bodies as the find routes. `DELETE /api/manual-buys/:id` removes a wrong entry.
- `GET /api/budget?month=2026-09` returns all the data of the Budget view for that month in one reply.
- `PUT /api/budget/limit` with `{"month": "2026-09", "limitUsd": 1000}` sets the buy limit from that month on.
- A bad price, date or month gets a 400 with a JSON error. An unknown ID gets a 404.

The hard rules:

- Paid prices, sold prices, fees and buy limits never go into a Claude request. They get the same treatment as the eBay numbers under hard design rule 1. `GuardTest.res` gets a case for each: it enters the value, builds a Claude request, and searches the request JSON for the value. M1 lite adds the case for sold prices.
- The spend counts every buy. A buy of a fixture find counts too, because the paid price is Dwight's own entry, not a model estimate. M1 lite keeps fixture rows out of its calibration, and that rule does not change.
- Tests and smoke tests keep the store in a temp folder, as `HaulTest.res` and `scripts/haul-smoke.mjs` do. Fixture buys then never reach `data/reflip.db`.

The page:

- The view switch gets a Budget entry. The UI/UX polish track owns the switch. The URL hash holds the view name (`#budget`), so a reload keeps the view and a test can open it directly.
- Each gem card in the haul view gets a Bought control. A bought card shows its paid price and an Edit control.
- The Bought sheet has the price (`inputmode="decimal"`), the date and Save. It shows what is left in the month of that date after this buy.
- The Sold sheet has the price, the date, the channel and the fees. It shows the profit while Dwight types.
- The page stays TEA: new `msg` variants in `AppState.res`, and effects in `App.res`. The price parse and the "left after this buy" figure come from `Money.res` and `Budget.res`, not from the view code.

## Decisions

- Build on the M1 lite columns in `finds`. Do not keep a second record of the same money.
- Keep manual buys in their own table. A find row needs a scene, a model and an estimate, and a manual buy has none of them. Placeholder values in `finds` make the find type false. The M1 lite calibration then has to skip them.
- Keep manual buys in the MVP. Without them, the spend misses each buy that no photo shows, and the left figure is wrong. In haul mode, the finds are only the gems, so a cheap buy that is not a gem also needs a manual buy.
- The buy limit applies to the spend, not to the spend minus the sales. Dwight asked to "max spend $1000 a month". The sales and the profit show next to the spend and do not change what is left. See Open questions.
- The buy limit is a warning, not a block. reflip knows about a buy only after Dwight enters it, so a block cannot work.
- Keep dollars in REAL columns, as the other money columns do, and add in whole cents in code.
- Draw the charts by hand, as SVG in ReScript. On 2026-09-25, `npm search` for "rescript chart" and "rescript svg" found no ReScript chart package. A chart library needs new bindings, and three simple charts do not need one. dippa has ReScript SVG charts in `src/ui/UiCharts.res` (`Sparkline`, `BigChart` and `PnlBar`). Start from them.
- Load the `dataviz` skill before the chart code, for colors that work in light mode and dark mode. Each chart gets a text summary for a screen reader.
- The haul budget and the buy limit are different things. The haul budget stops the Claude spend of one haul, and the buy limit is money for items. The haul view line "$x of $y budget" changes to "$x of $y Claude budget". The word budget alone then names only the new view.
- Claude cost does not count toward the buy limit. Later adds it next to the profit.
- Scan-mode buys wait for M1 lite. The scan routes (`POST /api/scene` and `POST /api/scene/stream`) write no finds today. Only haul mode writes them. Until M1 lite MVP step 2 is done, a buy from a scan is a manual buy.

## MVP

In order:

1. `Money.res` and `Budget.res`, with their tests.
2. Store: the `paidOn` and `feesUsd` columns with the migration, and the `manualBuys` and `buyLimits` tables. A store test opens an old database and makes sure that the migration keeps its rows.
3. Routes: the find routes, the manual-buy routes, `GET /api/budget` and `PUT /api/budget/limit`, with route tests. Add the `GuardTest.res` cases.
4. Page: the Bought and Sold sheets, the spend line in the haul view, and the Budget view with its tiles, its lists and Add a buy.
5. Charts: the three charts.
6. Smoke test. Extend `scripts/haul-smoke.mjs`, which runs the brain in fixture mode with a throwaway `DATA_DIR`. Use dev-browser at 390x844:
   - Start a haul, add `tests/fixtures/table.jpg`, and mark a gem Bought for $12. The haul view shows $12 spent.
   - Open Budget and set the buy limit to $10. The view shows "$2 over".
   - Add a manual buy of $3. The view shows $15 spent and "$5 over".
   - Sell the gem for $40 on eBay. The sheet fills in $5.84 in fees, and the profit is $22.16.
   - Take a screenshot of each state, and make sure that each number matches this list.
7. Ask Dwight to use it at the next sale.

## Later

- Scan-mode buys, from the find rows of M1 lite MVP step 2.
- The spend line in the haul email.
- The Claude cost of each month, next to the profit. Haul costs are in `scenes.costUsd`. Scan costs are only in `data/scenes.jsonl`.
- Lot buys, with one price for many finds. Until then, Dwight types the lot price on one find and $0 on the others. The spend of the month stays correct, but the profit of each item does not.
- A CSV of the buys through the share sheet, as `flip-scout.md` asks for each haul.
- Days to sell, and profit by category. M1 lite has days to sell in its Later list.
- Paid prices from the price tags in the photo. The haul spec has tag reading in its Later list.

## Non-goals

- A block on a buy.
- An import from a bank or a card.
- Sales tax and income tax.
- Currencies other than the US dollar.
- Any money figure in a Claude request.

## Risks

- Dwight forgets to enter buys, so the spend looks lower than it is. The Bought control is on the gem card that he already looks at, and the haul view shows the spend.
- A late entry gets the scan date by default. That is correct for a buy at the sale, and wrong for a buy on a second visit. The sheet shows the date, so Dwight can change it.
- If the buyer pays for shipping, the filled eBay fee is low. Until Dwight types the real fee, the profit is a little high.
- Two tracks change the page now: the UI/UX polish of the view switch, and the streaming scan UI on `claude/scan-ui`. Build the page part after both merge, or agree on the switch first.

## Open questions

- Does the buy limit apply to the spend, or to the spend minus the sales? This spec uses the spend.
- Does a change of the buy limit apply from the current month, or from the next month? This spec uses the current month.
- Does Claude cost count toward the buy limit? This spec says no.
- Is 14 days the right window for the gems in Add a buy?
