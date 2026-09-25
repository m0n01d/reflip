# Scan UI smoke test — iOS Simulator (iPhone 16e)

Branch: `claude/scan-ui-smoke-sim`, base `origin/claude/scan-ui` @ 49cdf33.
Server: `FIXTURES=1 FIXTURES_DIR=tests/fixtures/demo STREAM_FIXTURE_SPEED=3 PORT=8791`, fixture set `demo`.
Simulator: iPhone 16e, UDID 48CB0D7C-F62B-4DE3-87FB-5DF6B495A5A7, opened via `simctl openurl` to `http://127.0.0.1:8791/`.

Steps 5-9 (continued by a second agent) used two fresh servers instead: port 8791 at
`STREAM_FIXTURE_SPEED=1` (~115s scan, for the Stop test in step 5) and port 8789 at
`STREAM_FIXTURE_SPEED=10` (~12s scan, for steps 6-9).

Bugs found are recorded below the table, not fixed.

| step | control | expected | observed | pass/fail | shot |
|---|---|---|---|---|---|
| 1 | Pick a photo (or pick from your photos -> Photo Library -> first photo -> blue check) | ~3s later: dim numbered spot stickers on photo, no "not priced" text | Live scan started, "31 found so far", dim white spot stickers over items on the photo, no "not priced" text anywhere | pass | sim-spot-early.png |
| 2 | Wait for scan to end (~40s), then swipe down | Scan completes; swiping down reveals the results list | "0:37 Done", "14 worth a look", 35 items on the table, orange numbered price stickers on photo; swipe down revealed "Worth a look" list of 14 priced items (name, price range, confidence) | pass | sim-done.png, sim-done-list.png |
| 3 | Tap a priced (orange numbered) sticker, then close | Item sheet opens with detail; closes back to the done view | Tapped #39: sheet opened with photo crop, "Cluster of vintage clear glass bottles", $15-40 estimate, "fair guess 40%", eBay search box + "See sold listings". X closed it back to the done/results view cleanly | pass | sim-sheet.png, sim-sheet-closed.png |
| 4 | Tap a dim (non-orange) sticker that has no "worth a look" badge | "not priced" shown | Tried 3 different dim stickers (#25, #10, #29). All three opened the same item-sheet layout with an actual price estimate ("rough guess", $5-12 / $8-18 / $8-18) — none showed "not priced" text. Dim just means "below the worth-a-look bar", not "unpriced" | fail | sim-not-priced.png |
| 5a | Pick a photo (speed-1 server, port 8791), wait ~10s (actually tapped at 0:38 of a live scan), tap Stop | Stopped view that keeps what it found | Tapped Stop mid-scan (31 found, 0:38). Briefly showed "Stopping / Finishing up the items already found." (0:42), then settled at "Stopped / Kept the 31 items found so far." with "1:00 Stopped by you" in the log and an "Also seen - 31" section. "New scan" button replaced Stop | pass | sim-stopped.png |
| 5b | Tap "New scan" | Ready view | Returned cleanly to the "What's on the table?" ready view: Snap a photo button, "or pick from your photos" link, Scan\|Haul toggle | pass | sim-ready-again.png |
| 6 | Pick and wait for the end (speed-10 server, port 8789, ~12-15s), tap "Show the full log", then collapse | Log expands with per-item lines, then collapses | Scan finished at 0:11, "14 worth a look", "35 items on the table". Tapping "Show the full log" flipped the chevron and expanded to a `0:00  #1 Blue and white floral … $15-35` style line per item (#1-#8+ visible). Tapping again ("Hide the log") collapsed back to the summary row "worth a look  14 - $163-372" | pass | sim-log.png |
| 7 | From the Ready view, tap the settings (sliders) icon, then Done | Settings sheet opens, then closes | Sheet opened: "MODEL" (Opus 5.5 / Sonnet 5 selected, "median 0:47 and $0.15 a photo" / Haiku 4.5) and "PHOTO SIZE" (1568px selected / 2576px) radio groups, "Done" link top right. Tapping Done closed it cleanly back to the Ready view | pass | sim-settings.png |
| 8 | Tap the Scan\|Haul toggle to Haul, then back to Scan (no haul started) | Haul mode UI, then back to the Scan Ready view | Haul tab showed "Haul mode", a "Store name (optional)" field, and a "Start haul" button (not tapped). Tapping Scan returned cleanly to the "What's on the table?" ready view | pass | sim-haul.png |
| 9 | From a finished (Done) scan, tap "Snap another". (The only such control is the top-right "New scan" link. There is no separate "Snap another" button.) | Ready view, or a camera view that can be cancelled | Returned cleanly to the "What's on the table?" ready view, the same as step 5b. No camera view opened | pass | sim-snap-another.png |

## Live run

Date: 2026-09-25. One real scan, live mode (`fixture: false`), server on port 8786, worktree
`scan-ui-live` off `origin/claude/scan-ui` @ fc18786. Same photo as the fixture runs above (s01,
the yard-sale table).

- First dots on screen: by 0:05 ("11 found so far", none over $20 yet). shot: live-early.png
- First price on screen: by 0:19 ("34 found so far, 3 worth a look so far", first sticker $15-35).
  A midway shot at 0:28 ("35 found so far, 10 worth a look so far") is live-midway.png
- End: 0:42, "Done". "19 worth a look", "39 items on the table". shot: live-done.png
- Run receipt (swipe down on the done view): "worth a look 19 · $223-540", full priced list.
  shot: live-done-list.png
- Item sheet on a priced sticker (#52, Scalloped glass serving tray, $10-25, rough guess 25%,
  eBay sold n=50 median $16): shot: live-sheet.png, closed cleanly
- Item count: 39 items on the table (UI), 19 worth a look. The scene JSON carries 21 priced
  items. All 21 have eBay stats merged in. Most have n=50 sold comps. A few are thinner: two
  items have only n=1 and n=2
- Receipt numbers (from `data/scenes.jsonl`, sceneId `4117e5bb-f0eb-431f-9aa1-23e468d3178f`):
  model `claude-sonnet-5`. Main pass: serverMs 42138, claudeMs 39383, ebayMs 2684, cost $0.047136
  (input 5698 tok, output 3574 tok, cacheRead 0, cacheWrite 0, webSearches 0). Spot pass: cost
  $0.016884 (input 3007 tok, output 1087 tok). Total cost: $0.06402, against a $0.30 budget.
- Step 9 (Snap another / New scan from Done): pass, see the table above. No retry: this was the
  one live scan for this PR.
