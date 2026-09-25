# Fixtures

These files are synthetic. Nobody captured them from a real call.

We shaped `claude-scene.json` and `claude-haul.json` from the Messages API,
per the claude-api skill. `claude-haul.json` is the haul prompt's shape
(step 4): each item has a `where`, and the reply has a top-level
`otherCount`. Its third item's `estimateHighUsd` (15) sits under the
default $20 gem threshold on purpose, to prove the threshold is code, not
the prompt. We shaped each `ebay-search-*.json` from the eBay Browse API,
per `~/code/yard-sale/worker/ebay.ts` and eBay's own docs. `table.jpg` is a
small generated image, not a real photo.

`table.jpg` is 64x48 pixels. Each item in `claude-scene.json` has a `box`
in pixels of that image, so fixture mode shows boxes when you send
`table.jpg`. With any other photo, the boxes stay near its top-left corner.

`claude-haul.json`'s first two items have a `box` in the same pixels of
`table.jpg`, so a haul find gets an item box too (PR #8's follow-up). Its
third item's box is `[50, 30, 46, 40]`, x2 at or below x1 on purpose, so
Box.decode drops it and that find stores no box.
