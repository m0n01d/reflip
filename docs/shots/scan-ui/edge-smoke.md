# Scan UI edge-case smoke test

Branch `claude/scan-ui-smoke-edge`, off `origin/claude/scan-ui` @ `20ce7cc`. Headless
Chromium via `dev-browser`, 390x844 viewport. Photo: `tests/fixtures/demo/s01-1568-sent.jpg`
(1568x1176), fixture data `tests/fixtures/demo`.

Servers (all `FIXTURES=1 FIXTURES_DIR=tests/fixtures/demo`):

- `:8792` `STREAM_FIXTURE_SPEED=10` — scenarios A, C, D.
- `:8790` `STREAM_FIXTURE_SPEED=10 STREAM_DROP_AFTER_MS=3000` — scenario B.
- `:8790` (restarted) `STREAM_FIXTURE_SPEED=2`, no drop var — scenario E.

This run does not change app code. It only records what each edge case does.

## Results

| # | Scenario | Expected | Observed | Pass/Fail | Shot(s) |
|---|---|---|---|---|---|
| A | Spot stickers / not-priced gate | Early: dim stickers, no "not priced" text anywhere. After `end`: sticker counts settle, "not priced" shows for each unmatched spot item. | Early (1 s): 31 dim pins, 0 priced, no "not priced" text. After `end`: 35 total (21 dim / 14 priced). The "Also seen" list is collapsed by default, so its per-row "not priced" labels are not in the DOM until it is expanded — collapsed state has no "not priced" text either. After tapping "Also seen" to expand it: 13 of its 21 rows read "not priced"; the other 8 show a real sub-$20 price instead. | PASS (see note) | `edge-spot-early.png`, `edge-spot-end.png` |
| B | Drop and reconnect | "RECONNECTING" badge and "Connection dropped. Catching up…" during the gap. Then LIVE again, same end count as A, and `GET /api/scene/<id>/events?from=<n>` with n > 0. | Used `STREAM_DROP_AFTER_MS=3000` (the var exists in `src/stream/StreamRoute.res`; no `setOffline` fallback needed). Badge read "RECONNECTING", sub line read "Connection dropped. Catching up…", both present together. Reconnected to LIVE. End state matched A exactly: 21 dim / 14 priced, "14 worth a look". Reconnect request: `GET /api/scene/b8bdddec.../events?from=37`. One benign console error, `net::ERR_INCOMPLETE_CHUNKED_ENCODING` — that is the dropped socket itself, expected. | PASS | `edge-reconnecting.png`, `edge-reconnect-end.png` |
| C | New photo during a scan | Pick, then pick again 2 s later. Report whether a `POST .../stop` fires for scene 1. No sticker or log line from scene 1 after the second pick. | At 2 s into a Live scan, `document.querySelectorAll("input[type=file]")` returns **zero** elements anywhere on the page. `ScanShell`'s two pickers only render when `phase == Ready`; `ScanView`'s one picker ("Snap another") only renders once `isEnded(model)`. Neither is true 2 s into a run, so the second pick in this scenario cannot be performed — the given DOM snippet has no input to select. No second `POST /api/scene/stream` fired, so no `.../stop` fired either (confirmed: 0 stop requests, 1 total stream request). Scene 1 ran on undisturbed: "31 found so far" before and after the attempted second pick. | FAIL — scenario's precondition is unreachable through the UI (see note) | `edge-new-photo.png` |
| D | Failed first upload | An error state with a way to retry. Retry runs the scan to the end. | First `POST /api/scene/stream` aborted client-side (`net::ERR_ABORTED`) via `page.route`. App went straight to "Could not finish" / "Something went wrong. Kept what it found." / "Try again" button ­— effectively instant (this is a local network abort, not a round trip). Tapping "Try again" reset to Ready (2 file inputs back). Second pick's POST was let through and the scan ran the full 35-item demo to completion: "14 worth a look", matching A. | PASS | `edge-upload-failed.png`, `edge-upload-retry-end.png` |
| E | Stop timing | Report timing only — a known bug (fix on another branch) makes the fixture replay wait out its current event gap before honoring Stop. | At `STREAM_FIXTURE_SPEED=2`, tapped Stop 3 s after pick (state then: "12 found so far"). Headline read "Stopping" 231 ms after the tap (the immediate, client-only ack). The terminal `end` (status Stopped, headline "Stopped", "Stopped by you") landed 9,624 ms after the tap — the gap-wait bug. `POST /api/scene/<id>/stop` fired once, immediately. | REPORTED (timing only, no bug newly found beyond the known one) | `edge-stopped.png` |

**A note on A:** a shallow check right after `end` (page text for "not priced", without
interacting further) reads as a false fail, because the "Also seen" section that holds those
labels starts collapsed — it shows a name-only preview line until tapped open. Once opened, the
gate works exactly as `ScanState.isNotPriced` promises: unmatched spot items read "not priced";
matched-but-cheap items still show their price.

**A note on C:** `App.res`'s `onScanFileChange` guards against a stale in-flight handle
(`switch scanHandleRef.current { | Some(handle) => handle.abort() | None => () }`) before
starting a new run. That guard cannot currently be exercised from the UI — there is no picker
rendered anywhere during `Sending`/`Live`, so a same-tab "new photo while scanning" can't happen
through user interaction today. Worth a look, but out of scope here: this task records edge
cases, it does not change code.
