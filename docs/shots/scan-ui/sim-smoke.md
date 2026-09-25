# Scan UI smoke test — iOS Simulator (iPhone 16e)

Branch: `claude/scan-ui-smoke-sim`, base `origin/claude/scan-ui` @ 49cdf33.
Server: `FIXTURES=1 FIXTURES_DIR=tests/fixtures/demo STREAM_FIXTURE_SPEED=3 PORT=8791`, fixture set `demo`.
Simulator: iPhone 16e, UDID 48CB0D7C-F62B-4DE3-87FB-5DF6B495A5A7, opened via `simctl openurl` to `http://127.0.0.1:8791/`.

Bugs found are recorded below the table, not fixed.

| step | control | expected | observed | pass/fail | shot |
|---|---|---|---|---|---|
| 1 | Pick a photo (or pick from your photos -> Photo Library -> first photo -> blue check) | ~3s later: dim numbered spot stickers on photo, no "not priced" text | Live scan started, "31 found so far", dim white spot stickers over items on the photo, no "not priced" text anywhere | pass | sim-spot-early.png |
| 2 | Wait for scan to end (~40s), then swipe down | Scan completes; swiping down reveals the results list | "0:37 Done", "14 worth a look", 35 items on the table, orange numbered price stickers on photo; swipe down revealed "Worth a look" list of 14 priced items (name, price range, confidence) | pass | sim-done.png, sim-done-list.png |
