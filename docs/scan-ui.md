# Scan UI: plan and hand-off

This document plans the scan UI for reflip. It records the decisions for
this track, the event contract, the routes, the page flow, and the wave
split.

## 1. Decisions

1. **2026-09-25: add a spot pass.** The scan UI adds a second Claude call,
   with no tools. It returns only item names and boxes, not prices. It runs
   at the same time as the priced pass. A spike run found 22 items this
   way, at $0.035, with the first box at 4.1 seconds (`docs/stream-spike.md`
   §"Recommendation", item 4).
2. **2026-09-25: the match rule is an IoU of 0.5.** A spot item takes over
   a priced item's box at an IoU (intersection over union) of 0.5 or more
   (`Overlap.bestMatch`). Below 0.5, the spot item stays on the photo, dim,
   marked "not priced". In the spike, 17 of 22 spot items matched a priced
   item at this threshold, with a median IoU of 0.78.
3. **2026-09-25: a dropped connection must not stop the Claude call.** The
   route stops the call today, on any close. This must change. Stop must
   become its own request, apart from the stream connection. The page must
   get the scene id first, then it can ask for the scene again later.
4. **2026-09-25: this track builds now, on its own branch.** Branch
   `claude/stall-fix` fixes a separate problem, the Claude stall in the
   priced pass. This track merges after `claude/stall-fix` merges.

## 2. Event contract

Every event `POST /api/scene/stream` can send, from `src/stream/ScanEvent.res`.
The four `spot-*` rows come from the spot pass, a second, toolless Claude
call that runs next to the priced call (decision 1 above).

| Event | Data fields | When sent |
|---|---|---|
| `photo-received` | sceneId, bytes, width, height | Once, right after the photo arrives, before the Claude call starts |
| `claude-started` | t, inputTokens | When the Claude stream sends `message_start` |
| `thinking` | t | When a thinking block starts |
| `tool-run` | t, id, name | When a tool call runs (for example `code_execution`) |
| `tool-done` | t, id, name, status | When that tool call closes |
| `search-started` | t, id, query | When a web search block starts |
| `search-done` | t, id, count | When a web search returns results |
| `search-failed` | t, id, errorCode | When a web search returns an error |
| `box` | t, index, box | When one item's box closes in the streamed JSON |
| `item` | t, index, item | When one item's full JSON object closes |
| `done` | claudeMs, inputTokens, outputTokens, webSearches, usd | Once, when the Claude stream sends `message_stop` |
| `scene` | the scene reply itself (no wrapper) | Once, after eBay prices are merged in, right after `done` |
| `error` | t, message | On a decode error for one item, or on a Claude API failure, a timeout, or a missing API key |
| `stop` | t | When a stop request arrives through `POST /api/scene/:id/stop` |
| `spot-started` | t, inputTokens | When the spot pass's Claude stream sends `message_start` |
| `spot-item` | t, index, name, box | Once for each item the spot pass finds, at most 30 (indexes 0 to 29) |
| `spot-done` | t, claudeMs, inputTokens, outputTokens, usd | When the spot pass's Claude stream sends `message_stop` |
| `spot-failed` | t, message | If the spot pass fails, times out, or finds no fixture in fixture mode |
| `end` | t, status (`done`, `stopped`, `failed`, or `timeout`) | Always last, once for every scene |

`ScanEvent.res` has no Node import. `src/web/` can import it too, the same
way it already imports `Shared.res`.

## 3. Routes, now and planned

**`POST /api/scene/stream` (now).** The route takes a photo and streams the
events from §2. It makes one `AbortController` for the Claude call.
`SceneRegistry` buffers every event and keeps the scene running after a
client disconnects. Per decision 3, only a stop request or the 180 second
time limit aborts the Claude call now. A dropped connection alone does
not.

**`GET /api/scene/:id/events?from=<n>` (now).** This route replays the
scene's buffered events, starting at index `n`. The default for `n` is 0,
so a caller that leaves it out gets the full buffer. After the replay, the
route stays open. It sends new events live, until the `end` event closes
the connection. It returns a 404 JSON error when the scene id is unknown
or expired.

**`POST /api/scene/:id/stop` (now).** This route ends a scene on purpose,
apart from the stream connection. It returns 202 when the scene is still
running and accepts the stop. It returns 404 when the scene id is
unknown. It returns 200 with the scene's end status when the scene
already ended.

**Scene storage (now).** `SceneRegistry` keeps an ended scene for 30
minutes, in the `SCENE_KEEP_MS` constant. It checks for expired scenes
each time a new scene starts, and removes them.

## 4. Page flow by design moment

**Ready.** The page shows the camera control. No request has gone out yet.

**Sending.** The user sends a photo. The page shows the photo with a
sending mark. It waits for `photo-received`.

**Thinking.** `claude-started` and `thinking` arrive. The page shows a
thinking line in an activity log. No box or item exists yet.

**Searching.** `tool-run`, `search-started`, `search-done`, and
`search-failed` arrive. The page adds one log line for each event.

**First finds.** The first `box` or `item` event arrives. The page draws
the first sticker on the photo.

**Midway.** More `box` and `item` events arrive. Each sticker sits on the
photo, dim, until its price lands. A `spot-item` lands as a small white
dot. The design gives a number only to a worth-a-look item, because the
number points to its row in the list.

**Done.** The `scene` event arrives, with eBay prices for each item. Each
priced sticker updates to show its price. A priced item with an IoU of 0.5
or more takes over its spot sticker (decision 2). The `end` event closes
the stream. A spot item still with no match stays a white dot. Its row
under "Also seen" reads "not priced".

**Item sheet.** The user taps a sticker. A sheet opens with that item's
full reply: name, price range, eBay stats, and the sold-search link.

**Timeout.** The 180-second limit passes before the `scene` event arrives.
An `error` event, then an `end` event with status `timeout`, arrive. The
page shows a timeout state.

**Stopped.** The user taps Stop. The page sends `POST /api/scene/:id/stop`,
and the stream ends with status `stopped`. The page reads `Stopping`, then
`Stopped` with the items that it found. When the user leaves the page, the
connection closes, but the scene keeps running (decision 3).

**Reconnecting.** Per decision 3, if the connection drops, the page shows
a RECONNECTING badge. It reconnects with the scene id, through
`GET /api/scene/:id/events?from=<n>`. It replays the events that it missed,
then follows the scene live. If the replay gets a 404, the page shows
`Could not finish`.

## 5. Waves and file ownership

Each wave below owns a disjoint set of files, so two agents can work on
wave 2 and wave 3 at the same time without editing the same file.

**Wave 1 (this track, done).** `src/stream/ScanEvent.res`, `src/Overlap.res`,
their tests, and the `end` event wired into `src/stream/StreamRoute.res`.

**Wave 2 (brain, done).** The spot pass and the two new routes from §3.
Files: `src/stream` (all files), `src/SystemPrompt.res`,
`src/ClaudeClient.res`, `src/Server.res`, `src/Config.res`,
`tests/fixtures` and their tests.

**Wave 3 (page, done).** The page flow from §4. Files: `src/web` (all
files) and a new `ScanStateTest.res`, for a `ScanState.res` model built the
same way as `AppState.res`.

`ScanEvent.res` and `Overlap.res` have no Node import. Wave 3 can import
both, but wave 2 owns their edits.

## 6. Hand-off

- Status on 2026-09-25 at 20:45 UTC: `claude/scan-ui` holds waves 1 to 3, the spot pass, the brain and view fixes, main at `ddb30f5`, the Snap another fix (`c665f34`) and every smoke run. 787 checks pass on `44e3ec1`.
- PR: [m0n01d/reflip#19](https://github.com/m0n01d/reflip/pull/19), merged to main on 2026-09-25 with a merge commit. The images in its body point at `5d10c76`.
- Evidence is in `docs/shots/scan-ui/`. `sim-smoke.md` is Safari on the iPhone 16e, and it has the live run. `edge-smoke.md` has the Chromium edge cases. `taps-smoke.md` is the Chromium tap audit.
- Next step: two follow-up chips. "Close the scan UI design copy gaps" owns the view files. "Harden the scan stream route follow-ups" owns the brain files.
- Follow-ups are in the PR body.
