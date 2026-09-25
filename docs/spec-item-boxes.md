# reflip item boxes: see each item alone and in place

Status: proposal, written 2026-09-24. Dwight asked for it after a live test on a shelf of board games. The reply named each game, but the page did not show where each game was.

## Problem

The result view lists one card for each item, with no picture. On a shelf of 15 board games, Dwight must match each card to a spot on the shelf by eye. The haul digest in `docs/spec-haul-mode.md` (PR #6) has the same problem.

## How it works

1. The result view shows the photo once, at the top, at the width of the screen.
2. Each card shows a crop of its item from the photo, with a margin of 10% around the box. Dwight sees the item alone.
3. When Dwight taps a card, the page draws the box of that item on the photo and scrolls the photo into view. Dwight sees the item in place.
4. When Dwight taps inside a box on the photo, the page selects the card of that item and scrolls to it.
5. If an item has no box, its card shows no crop and the text "no box".

## What the Claude docs say

Read on 2026-09-24, in the vision guide "Coordinates and bounding boxes" (platform.claude.com/docs/en/build-with-claude/vision-coordinates) and on the Vision page.

- Claude returns absolute pixel coordinates in the image that it sees. Ask for `[x1, y1, x2, y2]` in pixel coordinates. Claude does not work well with normalized coordinates, for example 0 to 1000.
- The docs call the coordinates approximate. They say to state the format in the prompt and to look at the results before use at scale.
- Claude resizes an image that is over the limits of its model. Claude 4.7 and later models are on the high-resolution tier: 2576px on the long edge and 4,784 visual tokens. Other models are on the standard tier: 1568px and 1,568 tokens.
- Claude also pads the image to a multiple of 28px on the bottom and right. The padding does not move the origin. Rescale by the resized size, not the padded size.
- An image block can set `"transformations": {"oversized_image": "error"}`. If Claude must resize that image, the request returns a 400.

What this means for reflip:

- The page sends 1568px on the long edge. A 1568×1176 photo costs 56 × 42 = 2,352 visual tokens. Sonnet 5 and Opus 5.5 do not resize it, so each box maps one to one onto the photo.
- Haiku 4.5 is on the standard tier. It resizes that photo to fit 1,568 tokens, so the brain must rescale each box.
- The largest 4:3 photo that Sonnet 5 takes with no resize is 2212×1659, at 4,740 visual tokens. A bigger photo can help thin items such as book spines. The extra 2,388 tokens cost about $0.005 on Sonnet 5.

## Shape

- Schema: each item gets `box`, an array of four integers `[x1, y1, x2, y2]`, in pixels of the photo that the brain sent. The prompt gives the width and the height of that photo and asks for pixel coordinates.
- `Types.replyItem` gets `box: option<box>`. The decode returns `None` if the box is missing, has `x2 <= x1` or `y2 <= y1`, or lies fully outside the photo. It clamps a box that is partly outside.
- The reply gets `imageWidth` and `imageHeight`: the size of the photo that the brain sent.
- `ImageSize.res` ports the reference resize function from the guide. It is pure, with a test on the guide's examples. On the standard tier, 1075×1520 becomes 924×1307, and 1920×1080 becomes 1456×819. The high-resolution tier does not resize 1920×1080.
- The brain computes the size that Claude sees for the model of the request. If that size is not the size of the sent photo, the brain rescales each box to the sent photo.
- The page keeps the resized photo as an object URL in the model. It revokes the old URL when a new photo comes. This is an effect in `App.res`.
- The page draws the box as a `div` over the `<img>`, placed in percent: `left` is `x1 / imageWidth`, and so on. The crop is a `div` with the photo as its `background-image`, and `background-size` and `background-position` come from the box. Neither needs a canvas.
- TEA: `AppState.res` gets `selected: option<int>` and the msg `SelectItem(int)`. The view stays a pure function of the model.
- The fixture reply in `tests/fixtures/` gets a box for each of its 3 items, on the fixture JPEG. Fixture mode then shows boxes too.
- Haul mode: the `finds` table gets the box columns. The haul view loads the photo from a new route, `GET /api/scenes/:id/photo`, because the brain keeps it as `data/photos/<sceneId>.jpg`.

## Spike first

Before any page code, measure the boxes on real photos. This is rule 6 for fan-out in `~/code/CLAUDE.md`: a feature that depends on unknown API behavior starts with the smallest test that settles it.

1. Dwight puts his board-game shelf photos in `~/Pictures/reflip-m1/`. M0 does not keep photos, so the brain does not have them.
2. A script sends each photo to Sonnet 5 and asks for the names and the boxes only, with no web search. A scene with no search cost about $0.03 in the first experiment.
3. The script draws the boxes and the names on each photo and saves the images to `data/boxes/`.
4. It runs twice: once at 1568px on the long edge, once at the largest size with no resize (2212px for 4:3).
5. Dwight marks each box as good (it holds the item), loose (it holds the item and much else) or wrong.
6. Write the counts and the date into this spec.

The pass bar is a proposal: 8 of 10 boxes good or loose, on the median photo. If the photos fail the bar, show a point at the center of each box. Or keep only the `where` phrase from the haul spec.

The spike costs about $0.03 a call. With 13 photos at 2 sizes, that is 26 calls, under $1.

## MVP

In order:

1. The spike, with the results in this spec.
2. The schema, the decode with the clamp, `ImageSize.res` and the rescale, each with a test. `GuardTest.res` still passes.
3. The page: the photo at the top, the crop on each card, and the box on select. A tap in a box selects its card.
4. Smoke test: dev-browser at 390x844, in fixture mode, then with one live photo. Tap each card and each box, and look at a screenshot of each state.
5. A PR with before and after screenshots, as the PR rules in `~/code/CLAUDE.md` say.

## Order with haul mode

The haul build is in progress. It edits the same files: `SystemPrompt.res`, `Types.res`, `Shared.res`, `AppState.res` and `App.res`. Start step 2 after the haul MVP merges, on a branch from origin/main. The spike touches none of those files, so it can run now.

## Later

- Crops in the haul digest email. Node has no canvas, so a crop on the brain needs an image library. Put the choice through the package gate in `~/code/CLAUDE.md` first.
- A second look at a small item: send its crop back to Claude. The guide advises a crop for fine targets.
- A box on the live camera view, as `flip-scout.md` in app-ideas describes.

## Risks

- Dense shelves. A box can take in part of the next spine. The 10% margin on the crop hides a small error, but not a wrong box.
- Output tokens. A box adds about 15 to 20 output tokens for each item. At 19 items, that is about $0.003 more on Sonnet 5.
- Orientation. `Resize.res` decodes with `imageOrientation: "from-image"`, so the pixels that Claude sees are the pixels that the page draws. A test with a rotated EXIF photo proves it.
