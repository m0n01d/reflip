# Spec: a quarter for scale

Status: building. Written 2026-09-25.

## Why

For some items, the size decides which product it is. A Pyrex 401 bowl and a Pyrex 404 bowl are different listings. The same is true for Dutch oven quarts, cast iron skillet numbers, framed art and planters. The model writes the eBay `query`, so a size in the query gives a narrower set of eBay prices.

A US quarter is 24.26 mm across. If the user puts one next to the items, the model has a known length in the photo. Nobody measured yet how well the model uses it. The live test at the end of this spec measures that.

## Cost

The quarter adds no image tokens. The page scales each photo to the same long edge, whatever is in it. The prompt gets about 40 more input tokens, under $0.0001 a photo on Sonnet 5. The first live haul cost about $0.14 a photo. Each item gets a short `size` string, a few output tokens.

## Prompt

Both prompts in `SystemPrompt.res` get this text, in our own words:

- A single US quarter (24.26 mm across) can lie next to the items as a scale reference. If you see one, use it to measure the items near it.
- Do not list the quarter as an item. In haul mode, do not count it in `otherCount`.
- A new item field, `size`: the size of the item when size changes what it is or what it sells for. Examples are "10 in skillet" and "2.5 qt". Else an empty string. If size matters, put it in the `query` too.

The scene prompt also asks for `quarterSeen`: true if a quarter is in the photo, else false.

The prompt versions change to `scene-2` and `haul-3`. A find row then shows which prompt made it.

## Schema and types

1. `itemSchema` and `haulItemSchema` get a required `size` string.
2. `responseSchema` gets a required top-level `quarterSeen` boolean. `haulResponseSchema` does not get it.
3. `Types.claudeItem`, `Types.replyItem` and `Types.haulGem` get `size: string`. Their encoders write it.
4. `Types.sceneReply` gets `quarterSeen: bool`. `encodeSceneReply` writes it, so each line in `data/scenes.jsonl` has it.

A missing `size` decodes as `""`, and a missing `quarterSeen` decodes as `false`. This rule applies to the Claude decode in `ClaudeClient.res` and to the decoders in `Shared.res`. The retry without `output_config` has no schema, and older log lines do not have the fields.

## Store

The `finds` table gets a `size TEXT` column. `CREATE TABLE IF NOT EXISTS` does not add a column to the live `data/reflip.db`. So when `Store` opens the database, it reads `PRAGMA table_info(finds)`. If the `size` column is missing, `Store` runs `ALTER TABLE finds ADD COLUMN size TEXT`. A NULL `size` decodes as `""`.

## Page and email

The streaming scan screen and PR #8 (item boxes) also change `App.res`. So the page changes stay small:

- `ItemCard` and `GemCard` show the size after the name, when it is not empty.
- The scene result shows one line: "Quarter: seen" or "Quarter: not seen".
- The scene and haul capture screens show one hint: "Put a quarter next to small items to show their size."

In the haul email, `Digest.gemText` and `Digest.gemHtml` show the size after the name, when it is not empty. The HTML escapes it.

## Tests

1. Both prompts contain "24.26 mm". Both item schemas require `size`. Only the scene schema requires `quarterSeen`.
2. The prompt versions are `scene-2` and `haul-3`.
3. The Claude decode gives `""` for a missing `size` and `false` for a missing `quarterSeen`.
4. `encodeSceneReply` and `decodeSceneReply` keep `size` and `quarterSeen` on a round trip.
5. `Store` opens a database with the old `finds` table, adds the column, and keeps a find with its size. A second open does not fail.
6. The digest text and HTML show a size that is not empty, and show nothing extra for an empty size.
7. `tests/fixtures/claude-scene.json` and `claude-haul.json` get `size` values. The scene fixture gets `quarterSeen: true`.

## Done

1. `npm test` passes.
2. With `FIXTURES=1 PORT=8787 npm start`, a POST of `tests/fixtures/table.jpg` to `/api/scene` returns `quarterSeen` and a `size` on each item.
3. Screenshots at 390x844 in `docs/shots/` show the scene result and the haul view with sizes, before and after.

## Live test

After the merge, Dwight runs this in scene mode with the live key:

1. Pick five items of known size. Use at least one where size decides the product.
2. Photograph each item once with a quarter next to it and once without.
3. For each reply, write down the `size`, the `query` and `quarterSeen`. Measure each item with a ruler.
4. Write the results in `docs/`. Note the size error with the quarter and without it.

That is ten photos, about $1.40. Until the eBay keys are in, compare the `query` text, not the eBay price spread.

## Not in scope

- Other reference objects, such as a card or a ruler.
- A flag to turn the prompt text off. The text does nothing when no quarter is present, and `quarterSeen` shows a false detection.
- Photos of coins for sale. The prompt names one quarter that lies alone, but a coin lot can still confuse it.
- `quarterSeen` in haul mode. Haul mode stores only `size`.
