# Scan UI gap pass — evidence and smoke notes

This file assembles four runs. Only shot file names change below. The two
smoke reports keep their own words, unedited.

1. Chromium, through dev-browser, viewport 390×844, fixture brain,
   ebay.com blocked. Commit ac2c78e. See "Scan UI smoke test report"
   below.
2. A Chromium repeat of the same static screens, at commit 6a40e21. It
   found 0 of 35 dots covered. No shot from this repeat is in this set.
3. Safari on the iPhone 16e simulator. Commit ac2c78e. See "Reflip scan
   UI smoke test — iPhone 16e simulator" below.
4. The no-eBay run, at commit efb18b9. See "No-eBay run" below.

The before shots came from the base commit a3b821a.

---
# Scan UI smoke test report

Branch claude/scan-ui-copy, worktree scan-ui-copy. The shots below came from
HEAD ac2c78e.

## A note on HEAD drift

This worktree is shared with other sessions. While this report was in
progress, HEAD moved from ac2c78e to 6a40e21, three commits ahead:

- 2e826e0 Decide the item sheet's eBay panel state once, not twice
- 6f8392a Use stdlib Float.toFixed instead of a hand-rolled toFixed external
- 6a40e21 Fix two stale comments in BoxLayout.res and ScanState.res

`git diff --stat ac2c78e HEAD` touches src/web/App.res, BoxLayout.res,
ScanState.res, and ScanView.res. This report was not re-shot against the new
HEAD. The brief forbids running the browser scripts again. Commit 2e826e0
names the eBay panel state. That is the same area as one open point below.
This report does not confirm whether that point, or the eBay gaps below,
still hold at current HEAD. Treat every finding below as evidence about
ac2c78e, not a claim about 6a40e21.

## Click path table

| Step | Control | Expected | Observed | Result | Shot |
|---|---|---|---|---|---|
| scan-shots: dots | Dot overlay on the photo | No pin sits on top of another | 35 total pins, 0 covered | Pass | gaps-after-dots.png, gaps-after-dots.json |
| scan-shots: covered tap | Tap a covered pin | A screenshot of the tap | No covered pin existed to tap, so no shot was made | N/A. Expected on the fixed branch, not a failure | none |
| scan-shots: tap Item 1 | Tap the pin | The item sheet opens with a title | Opened. Title "Blue and white floral transferware divided bowl" | Pass | gaps-after-item.png, gaps-after-clicks.json |
| scan-shots: tap Item 9 | Tap the pin | The item sheet opens with a title | Opened. Title "Amber apothecary bottle" | Pass | gaps-after-clicks.json |
| scan-shots: tap Item 12 | Tap the pin | The item sheet opens with a title | Opened. Title "clear glass jar with lid" | Pass | gaps-after-clicks.json |
| live-flow a | Tap the settings chip | The Settings sheet opens, fits the screen, and lists Sonnet 5 first | Chip bottom sat at 818px in an 844px screen. First model label read "Sonnet 5" | Pass | gaps-after-ready.png, gaps-after-settings.png |
| live-flow b | Open the live eBay sheet | The flag reads "after Claude" and the title reads "Checking active listings" | Both matched, plus the hint line | Pass | gaps-after-live-sheet.png |
| live-flow c | Tap the run log toggle | The button shows a line count, then the log expands and collapses | Button read "Run log · N lines". aria-expanded went false, then true, then false. The shown lines matched N | Pass | gaps-after-log.png, gaps-after-log-open.png |
| live-flow d | Tap "Also seen" and "Snap another" | "Also seen" expands. The receipt shows resize and round-trip rows. "Snap another" opens a file picker | aria-expanded went false then true. Receipt had a Resize row (61 ms) and a Round trip row (0:11). Snap another showed a camera icon and fired a real filechooser event | Pass | gaps-after-also-open.png, gaps-after-snap-after.png |
| live-flow e | Stop a live scan, then reopen an item sheet | No stale "after Claude" state shows after a stop | Checked three times, no stale state found. One open point below | Pass, with one open point | gaps-after-stopped-sheet.png |

## The open point on state e

The exact "No eBay stats" text with an ended note never showed up in any
run. In fixture mode, an eBay lookup is a local JSON read. It resolves
before the stop-and-reopen round trip ends, even for the newest gem. The
script logged this as `raceNote`, not a failure. This is a fixture-speed
property, not a script bug.

## Dots numbers

- Total pins: 35
- Covered pins: 0
- Covered dot list: empty
- Three pin taps, all opened with no error: Item 1 → "Blue and white floral
  transferware divided bowl", Item 9 → "Amber apothecary bottle", Item 12 →
  "clear glass jar with lid"

## Design vs app differences

Checked with `scripts/side-by-side.py` against `docs/shots/design/`.

- **Ready** (gaps-compare-ready.png). No difference found. The headline, the body
  line, the camera button, the "or pick from your photos" link, and the
  model chip "Sonnet 5 · 1568 px" all match the design.
- **Settings** (gaps-compare-settings.png). No difference found. The model order
  is Sonnet 5, then Opus 5.5, then Haiku 4.5 in both. The photo size rows
  match too.
- **Done** (gaps-compare-done.png, gaps-after-done-full.png). The log button format
  matches ("Run log · N lines"), and the "Worth a look" heading with its
  "high estimate $20 or more" subtitle matches. Two gaps found:
  - The design shows a single "No eBay stats" notice box on the Done
    screen, above the Run log row. The app's Done screen has no such box
    anywhere. The same "No eBay stats" text only shows up per item, inside
    each item's own eBay block.
  - The design shows a second summary row under "Worth a look", "All N
    items  $X-Y". This row does not appear on the app's Done screen, in
    either the cropped or the full-page shot.
- **Item** (gaps-compare-item.png). The price label "Claude's estimate" and the
  confidence dots and text ("●●○○○ fair guess 0.40") match the design
  exactly. Three gaps found:
  - The design's sheet header reads "ITEM 8 OF 22". The app's sheet header
    reads only "#39", with no "of total" count.
  - The design's eBay button reads "Check sold prices on eBay". The app's
    button reads "See sold listings".
  - When there are no eBay keys, the design's eBay header shows a
    right-aligned "stats off" label next to the word "eBay". The app's
    per-item block does not show that label in the same spot.
- **EbayBlock** (gaps-compare-ebayblock.png, paired with gaps-after-live-sheet.png).
  The "after Claude" flag, the "Checking active listings" title, and the
  hint line "Claude's estimate shows first. eBay numbers are added after
  it." all match the design's loading mock word for word. Two gaps found:
  - The design's loading mock shows a filled progress bar. The app's live
    block shows no progress bar in the same state.
  - The design's mock does not show a search query line while still
    loading. The app shows the search query line immediately, before the
    check finishes.
  The same eBay button text gap from the Item comparison repeats here.

## Stopped sheet and receipt

**gaps-after-stopped-sheet.png.** Item #33, "Stack of vintage white dinner
plates", $10-22, "fair guess" at two of five dots. The top bar reads "New
scan", not "Stop" or "LIVE", so the stop had already taken effect. The eBay
block shows resolved stats as plain text: "active asking prices, not sold",
"n=5 15-31", "median 22". The design's matching mock draws these same
numbers as a box-and-whisker chart. The app shows them as text only, with
no chart.

**gaps-after-done-full.png.** The full receipt lists 14 "worth a look" items,
each with a price range and a "fair guess" or "rough guess" tag. Below that
sits "Also seen · 21" as a collapsed row. Below that sits a "RUN RECEIPT" block with eight rows:

- Model: Sonnet 5
- Photo: 1568 × 1176, 0.4 MB
- Resize: 58 ms
- Claude: 0:11
- Round trip: 0:11
- Tokens: 60,202 in, 10,605 out
- Web searches: 3
- Cost: $0.2565

The "Snap another" button at the bottom carries a camera icon, as expected.
No "No eBay stats" notice appears anywhere on this page. That matches the
Done-screen gap noted above.

## Brain

Stopped PID 99477 (smoke-dev-brain.mjs) after this report was written.
HANDOFF.md has that step marked done.

---
# Reflip scan UI smoke test — iPhone 16e simulator

Branch under test: claude/scan-ui-copy at ac2c78e. Simulator
48CB0D7C-F62B-4DE3-87FB-5DF6B495A5A7, Safari, brain on port 8796.

## Click-path table

| Step | Control | Expected | Observed | Pass/Fail | Shot |
|---|---|---|---|---|---|
| 1 | Ready view (`http://127.0.0.1:8796/`) | "What's on the table?" heading, Snap-a-photo button, and the model/size chip all render. No scroll is needed | Matched. The full view rendered. No scroll was needed | PASS | gaps-sim-ready.png |
| 2 | "Sonnet 5 · 1568 px" chip | Opens a Settings sheet. It lists models (Sonnet 5, Opus 5.5, Haiku 4.5) and photo sizes (1568 px, 2576 px). It closes with Done | Matched. Sonnet 5 and 1568 px showed as selected, first in each list. It closed with Done | PASS | gaps-sim-settings.png |
| 3 | Tap a priced (orange) sticker while the scan is still live | The eBay block on that sticker's sheet shows "after Claude" and "Checking active listings", because item.ebay is still unresolved | NOT CAUGHT. See the note below | FAIL for the transient text. PASS for the live-tap mechanic itself | none (no gaps-sim-live-sheet.png) |
| 4a | "Run log · N lines" row | It expands to a timestamped, per-item log | Matched. It expanded to per-item lines, for example "0:02 #1 Blue and white floral … $15-35". The chevron flipped to point up | PASS | gaps-sim-log.png |
| 4b | Scroll to the run receipt | A "RUN RECEIPT" card shows Model, Photo, Resize, Claude, Round trip, Tokens, Web searches, and Cost. A "Snap another" button sits below it | Matched. All fields were present. The Snap another button shows a camera icon next to the label | PASS | gaps-sim-receipt.png |
| 5 | Tap a priced sticker (post-Done) | The sheet shows the item title, a price range labeled "Claude's estimate", a confidence row with a numeric score, and a resolved eBay header (listing count, median, searched query) | Matched. Item #2, a ceramic Christmas village church: $8-20, "fair guess" confidence 0.50, eBay 5 listings, median 17, "See sold listings" button | PASS | gaps-sim-item.png |
| 6 | Tap a white (unpriced) dot in a dense cluster | Its own sheet opens. It is marked not priced | Matched. Item #19, "small ceramic cup striped2 — not priced". It shows a white ring icon, not an orange numbered badge | PASS | gaps-sim-dot-tap.png |

## Note on step 3

Two live-scan attempts ran, each on a fresh scan. Both used the same brain: port
8796, PID 32337, speed 1.

- Attempt 1: a batch of new orange badges appeared on screen. A tap landed on
  one within a few seconds. The sheet that opened was already fully resolved.
- Attempt 2, on a second scan: tighter polling caught the first orange pixels
  on the canvas. A tap landed about one poll cycle later. The result was the
  same: item #1's sheet opened already resolved.

Both times the scan was still live in the background (the Stop button still
showed). So the live-tap interaction itself is not broken. What stayed open is
whether the "after Claude" and "Checking active listings" copy ever stays on
screen long enough for a human or a scripted tap to catch it, at least for this
fixture and this item. A direct check of the source condition would answer this
better than another timing-based UI retry: item.ebay is None, model.sceneReply
is None, and the scan has not ended.

## What ran and what did not

- All 6 steps ran against a real, booted simulator and a real running brain
  process. Steps 1, 2, 4, 5, and 6 passed, each with a saved screenshot. Step
  3's transient copy did not appear in either attempt. The rest of step 3, the
  live-tap mechanic, did work.
- No source file was edited. No commit was made or needed.
- A third scan attempt did not run. The turn-counter fired during the second
  attempt's follow-up. The brief says to start no new step at that point.

## No-eBay run

The brain ran with `FIXTURES=1`, a no-key fixture set as `FIXTURES_DIR`,
and `STREAM_FIXTURE_SPEED=10`, at commit efb18b9. `scan-shots.mjs`
captured the same views as the other Chromium run, with ebay.com
blocked. The dot-tap shot did not run. This fixture set covered 0 of 35
dots, the same limit seen in the other two Chromium runs.

The Done screen lists "14 worth a look" from "35 items on the table",
with a "Run log · 26 lines" row. Below that row sits the "No eBay
stats" notice. The bold title "No eBay stats" and the line below it,
"No item had eBay stats.", now sit on two lines. See
`gaps-noebay-done.png` and `gaps-compare-done-noebay.png`.

The item sheet is item #39, "Cluster of vintage clear glass bottles".
It shows a price of $15-40, labeled "Claude's estimate". It shows two
of five confidence dots and the tag "fair guess" at 0.40. Its eBay
block shows the bold line "No eBay stats". Below that line sit the
searched query "antique clear glass soda bottles lot" and a "See sold
listings" button. See `gaps-noebay-item.png` and
`gaps-compare-item-noebay.png`.

At commit 6a40e21, `scan.css` gave `.scan-noebay-title` and
`.scan-noebay-note` no `display` rule. Both lines ran together as one
line of text: "No eBay statsNo item had eBay stats." At commit
efb18b9, both rules read `display: block`. The two lines now render
apart, as the Done shot above shows.

One gap stays open. When no eBay keys exist, the design shows a
right-aligned "stats off" label next to the word "eBay" on the item
sheet. The app's item sheet does not show that label, in this run or
the earlier ones. Fixture mode never sends a scene note, so this flag
has no path to turn on. This gap is not the line-break bug above, and
this run does not close it.

## One name not backed by a shot

The simulator report above names `gaps-sim-live-sheet.png` once,
inside a note that no such shot exists. That name is not a file in
this set.
