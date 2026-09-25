# Scan UI click-path audit — spot dot, Worth a look, Also seen, sold link, Snap another

Branch `claude/scan-ui-smoke-taps`, base `d1030e4`. Headless Chromium via `dev-browser`,
390x844 viewport. Photo read directly from
`/Users/dwight/code/reflip/.claude/worktrees/admiring-kirch-eef695/data/boxes/s01-1568-sent.jpg`
(not copied into this repo, not committed), fixture data `tests/fixtures/demo`.
Server: `FIXTURES=1 FIXTURES_DIR=tests/fixtures/demo STREAM_FIXTURE_SPEED=10 PORT=8793`.

Steps 1-4 are controls no smoke run had tapped before this audit. Step 5 was added mid-run
at the coordinator's request. This run does not change app code — it only records what each
control does.

## Results

| step | control | expected | observed | pass/fail | shot |
|---|---|---|---|---|---|
| 1 | Tap a white (plain-badge) spot dot on the photo that has no match | The item sheet opens and reads "\<name\> — not priced" | Looped over the 21 plain-badge pins (`.scan-pin-badge-plain`); 8 were pointer-blocked by an overlapping pin's badge/callout and were skipped without failing the run. Pin `aria-label="Item 17"` (the 11th tried) opened a sheet reading "round glass bowl small — not priced" | pass | taps-dot-sheet.png |
| 2 | Tap a row in the "Worth a look" list | The sheet for that item number opens | Tapped row `#39 "Cluster of vintage clear glass bottles"`. Sheet kicker read "#39", sheet name read "Cluster of vintage clear glass bottles" — both match the row | pass | taps-worth-row-sheet.png |
| 3 | Expand "Also seen", then tap a row that reads "not priced" | The not-priced sheet opens | Row "glass bottle tall clear" (listed as "not priced") opened a sheet reading "glass bottle tall clear — not priced" | pass | taps-also-seen-sheet.png |
| 4 | In a priced item's sheet (#39, still open from step 2), tap "See sold listings" | An ebay.com sold-search URL with the item query; eBay is never loaded | The link's `href` and the actual outgoing request both read `https://www.ebay.com/sch/i.html?_nkw=antique%20clear%20glass%20soda%20bottles%20lot&LH_Sold=1&LH_Complete=1`. The context-level route abort (`**ebay.com**`, set up before any tap) caught the request before it loaded. The `target="_blank"` popup landed on `chrome-error://chromewebdata/`, never on ebay.com | pass | taps-sold-link.png |
| 5 | On the done view, set a new photo on the "Snap another" file input (`.scan-snap-another`, in the run-receipt area) | A new scan starts (a 2nd `POST /api/scene/stream`), the old stickers clear, and it runs to the end | **Bug, reproduced twice.** `setInputFiles` on the input succeeded (1 match, present, visible), but no 2nd `/api/scene/stream` request ever fired — the count stayed at 1 over a 10 s poll. Instead the whole view reverted to the Ready/home screen: `.scan-headline` and all 35 `.scan-pin` stickers vanished (0 count) within 500 ms and stayed gone for a full 20 s trace. Root cause, read directly from source: `src/web/ScanView.res:119`, `let onNewPhoto = (_: ReactEvent.Form.t) => dispatch(ScanState.NewScan)` discards the picked file and only dispatches `NewScan`; `src/web/ScanState.res:328`, `​| NewScan => initialModel` maps that straight to the blank Ready state. The photo picked on this control never reaches a scan | fail | taps-snap-another.png |

## Notes

- **Step 1 overlap.** Several `.scan-pin` buttons sit close enough on the photo that a
  neighboring pin's badge (here, pin #39's gem badge and price callout) intercepts pointer
  events on a pin underneath it. The audit's loop skips a blocked pin and tries the next one,
  so it did not fail the run, but a real finger on a dense photo would hit the same block.
  Worth a look, not fixed here — this run does not change app code.
- **Step 5 is a confirmed bug, not a script limitation.** It was reproduced twice — once in the
  full 5-control run, once in an isolated diagnostic that traced `.scan-headline` and
  `.scan-pin` counts every 500 ms for 20 s after the tap — and the root cause was read directly
  from `ScanView.res` and `ScanState.res`, not inferred from timing. "Snap another" looks like
  an inline re-scan control; it actually only resets to Ready and drops the new photo.
