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

Per `docs/spec-scale-ref.md`, `claude-scene.json` has `quarterSeen: true`
at the top level, and each fixture's items mix a `size` value, an empty
`size`, and a missing `size` key, so a decode exercises all three cases.

`table.jpg` is 64x48 pixels. Each item in `claude-scene.json` has a `box`
in pixels of that image, so fixture mode shows boxes when you send
`table.jpg`. With any other photo, the boxes stay near its top-left corner.

`claude-haul.json`'s first and third items (the lamp and the brooch) have
a `box` in the same pixels of `table.jpg`, so a haul find gets an item box
too (PR #8's follow-up). Its second item's box (the skillet, a gem) is
`[50, 30, 46, 40]`, x2 at or below x1 on purpose, so Box.decode drops it
and that find stores no box — the skillet is a gem, so this is the fixture
that proves a gem with no box works end to end, all the way through the
haul digest email.
