# reflip M1: learn from Dwight's own sales
Status: spec · Last researched: 2026-09-24
Verdict: build, about one weekend plus one evening. The rivals price a find the same way for every user. reflip has one user, so it can measure its estimates against Dwight's own sales, with no eBay access.

M1 of [Flip Scout](https://github.com/m0n01d/app-ideas/blob/main/ideas/flip-scout.md). Dwight set the scope on 2026-09-24: no eBay dependency, a small MVP, and all else in Later. The ideas come from the [research artifact](https://claude.ai/artifact/HQUYnsGJWrnaWzpHZZ7nqg) of the same day (private to Dwight).

## Problem

M0 answers one question for one photo: what is each item worth? It does not know whether the answer was right. Every run so far used `FIXTURES=1`, so even the cost per photo, $0.0287, is a synthetic number.

The rival apps price a find the same way for every user. A find is one item from one scene. reflip has one user and runs on Dwight's Mac mini. So it can keep a record of what Dwight paid and what each find sold for, and compare each sale with Claude's range. Without that record, no estimate can improve, and nobody can say whether Claude's ranges are right.

eBay has not approved Dwight's API access yet. M1 must work without it. Missing eBay keys already degrade cleanly: each item's `ebay` is null and `ebayNote` says why.

## How it works

Four moments, in order:

1. Scan. At a sale, Dwight takes a photo, as in M0. The brain writes one ledger row for each item in the reply. Each row gets a find ID.
2. Buy. When Dwight buys an item, Dwight taps it and types the price paid: the tag, or less after a haggle.
3. Sell. The item sells on eBay, on Marketplace, or for cash. Dwight opens the Finds view, taps the find, and types the sold price and the date. The sold price is the item price only, without shipping or tax.
4. Learn. The phone page shows a calibration readout, a report of how well past ranges matched real sales. Code computes it from the sold finds. It starts with one overall figure. A category gets its own figure after it has 10 sales.

The readout has two numbers. The hit rate is the share of sold finds whose sold price is inside Claude's range. The bias is the median of the sold price divided by the midpoint of Claude's range. A bias of 0.8 means that Claude runs 25% high.

All of this runs in code. Sold prices and the readout never go into a Claude request. They get the same treatment as eBay numbers under hard design rule 1.

## Shape

M1 adds to the M0 brain and page. It adds no service and no key.

- Ledger: SQLite, through the built-in `node:sqlite` module, in `data/reflip.db`. `data/` is gitignored already. Dwight chose SQLite over a JSONL file on 2026-09-24.
- Bindings: `src/bindings/` gets typed externals for the few `DatabaseSync` calls that the ledger uses. No `%raw` and no `Obj.magic`. Each row decode returns an option, like `Json.res`.
- One `finds` table. From `Types.sceneReply`: `sceneId`, `model`, `fixture`. From `Types.replyItem`: `name`, `estimateLowUsd`, `estimateHighUsd`, `confidence`. New: `findId` (from `crypto.randomUUID`), `category`, `promptVersion`, `paidUsd`, `soldUsd`, `soldOn`, `soldWhere`, `createdAt`.
- Category: the model returns none today. The structured-output schema in `SystemPrompt.res` gets a `category` enum, from a short fixed list in code.
- Prompt version: a hash of the system prompt text. If the prompt changes later, the old rows stay apart from the new rows in the readout.
- Routes: `GET /api/finds`, `POST /api/finds/:id/paid`, `POST /api/finds/:id/sold`, `GET /api/calibration`.
- `Calibration.res`: pure functions next to `Stats.res`, with a hand-computed test, as `PricingTest.res` does for cost. Rows with `fixture` set never count.
- Phone page: a Paid entry on each result item, a Finds view of the open finds, a Sold entry, and the readout. The page stays TEA: new `msg` variants in `AppState.res`, effects in `App.res`.
- `GuardTest.res` gets one more case: a Claude request built after a sold entry contains no sold price.

## Device requirements

- The Mac mini runs the brain, as in M0. `node:sqlite` runs without a flag from Node 22.13.0. It is a release candidate (Stability 1.2) from v25.7.0, per nodejs.org/api/sqlite.html on 2026-09-24. The MacBook had v26.0.0 that day. Nobody read the Node version on the Mac mini. Make sure that it is 22.13.0 or later before the first build.
- The iPhone 16 Pro runs the M0 PWA. Nothing new on the phone.
- The phone reaches the brain only through `tailscale serve`, and nobody has set it up yet. Until then, the page works in a browser on the Mac mini, and the smoke test runs there at phone width.

## MVP

About one weekend, after the first experiment. In order:

1. Run the first experiment below. It needs no code.
2. Ledger: the bindings, the `finds` table, the `category` field, and one row for each item in each scene.
3. Paid and sold entry: the routes and the phone page views.
4. Calibration readout: `Calibration.res`, its test, the route and the view. The readout shows the count of sold finds and a 95% interval for the hit rate. A small sample then does not look certain.
5. Smoke test: take a photo, enter a paid price, enter a sold price, and read the readout. Use the phone, or dev-browser at phone width. Passing tests do not make M1 done. This path does.

Dwight moved the walk-away price from the MVP to Later on 2026-09-24.

## Later

- Walk-away price for each item: Claude's range, minus eBay's fee and a shipping class, minus a minimum profit. First in line after the MVP.
- Apply the calibration: correct new estimates in code by the measured bias, per category. Only after a few dozen sales (see Risks).
- Whole-table offer that uses the uncertainty of each item. The artifact's simulator is the reference math. It treats Claude's range as an 80% interval and fits a lognormal. It adds a correlated error term and a sell probability. It leaves out the items that fail. The ledger then supplies measured values for the 80% and the sell probability.
- A `lookCloser` schema field: the one detail that moves the value most. If the two answers fall on opposite sides of the walk-away price, code asks for a second photo.
- A pickup-only flag, priced through the [USPS Domestic Prices 3.0 API](https://developers.usps.com/domesticpricesv3).
- A shelf check at scan time: what Dwight already owns, or passed on before. The unbought rows in the ledger are the start of it.
- A hunt list inside the live camera.
- A two-pass web search. The second pass searches only the items whose answer can change the decision. The first experiment says how much search costs.
- Days to sell: a listed date on each find.
- A sync of Dwight's eBay orders through `getOrders`. It waits for eBay access and for an answer on §9 (see Risks).

## What exists

One research agent swept vendor pages and app-store copy on 2026-09-24. Nobody tested any tool hands-on. This session read the FlipTip and Underpriced AI pages again with curl on 2026-09-24.

| Tool | Does | Gap for reflip |
|---|---|---|
| [FlipTip](https://fliptip.ai/) (web app, $9.99 to $39.99 a month) | Live AR arrows over a table, a highest price to pay, sell speed and batch scan. An AI Hunter over eBay listings only. A profit dashboard with manual paid and sold entry | Its FAQ does not say that sales correct its estimates |
| [Underpriced AI](https://underpricedai.com/faq) | Syncs eBay sales through the Fulfillment API | Its FAQ says that it does not retrain on user data |
| Flipr, [flippr.org](https://flippr.org/), SellerAmp | A max-offer price | The same price for every user |
| [Flippr](https://useflippr.com/), ThriftFlip, FlipTip, [ScoutIQ](https://www.scoutiq.co/features), [underpriced.app](https://www.underpriced.app/) | Sell-through or days to sell | From market data, not from the user's sales |
| Bookzy, Discogs | Buy advice that knows your inventory | Barcodes for books and records only |

No tool found compares its estimates with the user's own sales and corrects them. The ledger alone is not new, because FlipTip's dashboard takes the same manual entries. This session found that dashboard, and the research artifact does not list it. Open question: does FlipTip use the dashboard data in its estimates? Its FAQ does not say. Flipr, flippr.org and SellerAmp were not read again in this session.

Other facts that this spec uses, all read 2026-09-24:

- eBay fee: 13.6%, plus $0.30 per order at $10 or less, or $0.40 above that. eBay charges it on the total with shipping and tax, since 2025-02-14 ([eBay help](https://www.ebay.com/help/selling/fees-credits-invoices/selling-fees?id=4822)).
- Terapeak is free for all sellers ([Seller Center](https://www.ebay.com/sellercenter/growth/ebay-research-tools)).
- `getOrders` in the Sell Fulfillment API needs a user token from the authorization code grant, with the scope `sell.fulfillment.readonly`. It returns `lineItemCost` and `creationDate` for two years back.
- USPS Notice 123 prices changed three times in 2026, so use the prices API, not a table. eBay's Logistics API is Limited Release.
- Claude: Sonnet 5 is $2/$10 per MTok, Haiku 4.5 is $1/$5, Opus 5.5 is $4/$20, and a web search is $0.01. The system prompt is below the 1,024-token minimum for caching on Sonnet 5.

Struck claims:

- ~~Flip Scout scans a whole table from live video, not 20 stills. That is its edge over rivals.~~ FlipTip already draws live AR arrows over a table, as a web app. Read on fliptip.ai, 2026-09-24.
- ~~A max-offer price sets Flip Scout apart.~~ FlipTip, Flipr, flippr.org and SellerAmp all give one.

## Risks / unknowns

A skeptic's note.

- eBay API License §9. The agreement is now dated 2025-09-03, and `flip-scout.md` cites the 2025-06-24 version. Its §8.5 AI ban covers only "Restricted APIs". Its §9 bars the use of eBay Content "to suggest or model prices for items listed on eBay Site", with or without AI. A `getOrders` sync that feeds calibration is at risk. Today's Browse percentiles are possibly at risk too. Manual entry does not use the API, so M1 avoids the question. developer.ebay.com returned a 403, so the text came from Wayback snapshots dated April to August 2026. This is not legal advice.
- Too few sales. Calibration means little before a few dozen sales. At 20 sales and an 80% hit rate, the 95% Wilson interval is about 58% to 92%. At 50 sales, it is about 67% to 89%. Each category needs its own few dozen. Nobody knows Dwight's sales rate yet. The ledger itself measures it.
- The 80% assumption. The prompt asks for "a used resale range in US dollars" and states no coverage. The table offer in Later treats that range as an 80% interval. That is a guess until the hit rate measures it.
- A biased sample. Only sold finds count, and unsold finds drop out. If Claude's range looks high against the tag, Dwight also buys more often. So the bias describes the finds that Dwight buys, not Claude's general accuracy. That population is the one that matters for a buy decision.
- The sold price. eBay charges its fee on the total with shipping and tax. The ledger stores the item price only, so a later walk-away price adds the fee base back in code.
- `node:sqlite` is a release candidate, not stable. The bindings cover only the calls that the ledger uses, so an API change touches one file.
- The phone path needs `tailscale serve`, which is not set up.

## First experiment

One evening, before any M1 code:

1. On the Mac mini, put only `ANTHROPIC_API_KEY` in `~/.config/reflip/env`. Add no eBay keys.
2. Start the brain without `FIXTURES=1`: `PORT=8787 npm start`. The model is Sonnet 5, the default.
3. Open `http://127.0.0.1:8787/` in a browser on the Mac mini. Pick each photo from a file, so the page resizes it as the phone does.
4. Send 10 real scenes: tables of household items, not the fixture photo.
5. For each scene, read these fields from `data/scenes.jsonl`: `cost.usd`, `timing.claudeMs`, and `cost.webSearches`. The search share is `webSearches` × $0.01 ÷ `usd`.

The fixture is the baseline. It has 2,450 input tokens, 380 output tokens and 2 searches, for $0.0287. The two searches are about 70% of that. Search results bill as input tokens too, so real scenes likely have more input tokens than the fixture.

Decide from the medians. These thresholds are a proposal:

- If search is more than half of the cost, the two-pass search moves up in Later.
- If a scene costs more than $0.10, or Claude takes more than 20 s, measure a lower effort on Sonnet 5. Do that before any change of model, as the claude-api skill advises.
- Write the 10 rows and the medians in `CLAUDE.md`, next to the pricing table, with the date.

## Non-goals

- An eBay API call that M0 does not make already. No Fulfillment sync and no new Browse use.
- Sold prices, the ledger or the readout in a Claude request.
- A change to the shown estimate. M1 reports the bias and does not apply it.
- The walk-away price and the table offer. Both are in Later.
- Tag reading from the photo.
- Accounts, other users and cloud hosting.
