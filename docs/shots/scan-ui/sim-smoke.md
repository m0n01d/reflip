# Scan UI smoke test — iOS Simulator (iPhone 16e)

Branch: `claude/scan-ui-smoke-sim`, base `origin/claude/scan-ui` @ 49cdf33.
Server: `FIXTURES=1 FIXTURES_DIR=tests/fixtures/demo STREAM_FIXTURE_SPEED=3 PORT=8791`, fixture set `demo`.
Simulator: iPhone 16e, UDID 48CB0D7C-F62B-4DE3-87FB-5DF6B495A5A7, opened via `simctl openurl` to `http://127.0.0.1:8791/`.

Bugs found are recorded below the table, not fixed.

| step | control | expected | observed | pass/fail | shot |
|---|---|---|---|---|---|
| 1 | Pick a photo (or pick from your photos -> Photo Library -> first photo -> blue check) | ~3s later: dim numbered spot stickers on photo, no "not priced" text | Live scan started, "31 found so far", dim white spot stickers over items on the photo, no "not priced" text anywhere | pass | sim-spot-early.png |
| 2 | Wait for scan to end (~40s), then swipe down | Scan completes; swiping down reveals the results list | "0:37 Done", "14 worth a look", 35 items on the table, orange numbered price stickers on photo; swipe down revealed "Worth a look" list of 14 priced items (name, price range, confidence) | pass | sim-done.png, sim-done-list.png |
| 3 | Tap a priced (orange numbered) sticker, then close | Item sheet opens with detail; closes back to the done view | Tapped #39: sheet opened with photo crop, "Cluster of vintage clear glass bottles", $15-40 estimate, "fair guess 40%", eBay search box + "See sold listings". X closed it back to the done/results view cleanly | pass | sim-sheet.png, sim-sheet-closed.png |
| 4 | Tap a dim (non-orange) sticker that has no "worth a look" badge | "not priced" shown | Tried 3 different dim stickers (#25, #10, #29). All three opened the same item-sheet layout with an actual price estimate ("rough guess", $5-12 / $8-18 / $8-18) — none showed "not priced" text. Dim just means "below the worth-a-look bar", not "unpriced" | fail | sim-not-priced.png |
