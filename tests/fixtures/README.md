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
