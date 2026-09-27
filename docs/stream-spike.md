# Stream spike

Date: 2026-09-25. Branch: `claude/stream-spike`. Model: `claude-sonnet-5`.

The scan UI design shows each item on the photo when Claude finds it, next to a log of real events. `POST /api/scene` reads the whole Claude reply at once. On scene `5c0c5ba7` (22 items), the phone saw nothing for 2:46. This spike answers five questions before the UI build.

The brain keeps no photos. So all live runs used `s01-1568-sent.jpg`, the same table at the same size (1568 x 1176 px). All runs are from 2026-09-25.

## Short answers

| Question | Answer |
|---|---|
| 1. Can one call stream with structured output and web search? | Yes. A live test showed it, and the docs name no conflict. |
| 2. Can the brain send each item when its JSON object closes? | Yes. With search on, the first item came at 80 to 89 percent of the total time. |
| 3. Which stream events feed the UI log? | Each planned log line has an event. `search-started` is not live, so show progress at `tool-run`. |
| 4. Can Stop cancel the Claude call? Does the brain keep the items? | Yes, and yes. A live stream ended 13 ms after Stop. |
| 5. How do the items reach the PWA? | A `fetch` POST, with `response.body` read as SSE text. It streams live through `tailscale serve`. |

The largest finding is not about streaming. In 4 of 6 runs with search, a code step stalled for 90 to 96 s. Two of those 4 runs hit the 180 s limit. Each stall came in a run where the model started two or more code steps at once.

## 1. Stream, structured output and web search together

A `claude-code-guide` agent (haiku) read the docs on 2026-09-25. The structured outputs page says: "Structured outputs also work with streaming." `output_config.format` is GA and needs no beta header. The docs name no conflict with server tools or thinking. But no page shows the three together.

A live test on 2026-09-25 settled it. One request set `stream: true`, `output_config.format` with a JSON schema, and `web_search_20260209` with `blocked_domains: ["ebay.com"]`. The reply was HTTP/2 200 with `text/event-stream`, and its text decoded against the schema. After that, the six live runs with search below used all three together.

Sonnet 5 searches from inside code steps when it has `web_search_20260209`. Each `code_execution` step runs code that calls `web_search`. Sonnet 5 also thinks by default. Its thinking blocks arrive with empty text and a signature only.

## 2. Items from the partial JSON

`ItemScanner.res` reads the JSON text as it arrives. It sends a `box` event when the `box` array of an item closes. It sends an `item` event when the object of the item closes. In the three runs that ended normally, the streamed items equal the items of the final decode.

The runs, in seconds from the request start:

| Run | `box` in schema | Search | First text | First box | First item | Last item | End | Items | Cost |
|---|---|---|---|---|---|---|---|---|---|
| box-last-1 | last | on | 141.4 | 142.9 | 142.9 | 163.3 | 163.4 | 22 | $0.164 |
| box-last-2 | last | on | 157.9 | 159.3 | 159.4 | 179.3 | 180.0, limit | 21 | not known |
| box-second-1 | second | on | 89.2 | 89.5 | 90.2 | 112.6 | 112.6 | 22 | $0.257 |
| spot-1 | second | off | 3.5 | 4.1 | 5.4 | 28.0 | 28.1 | 22 | $0.035 |
| stop-1 | last | on | 55.1 | 56.8 | 56.8 | Stop | 56.8 | 1, kept | not known |
| scene `5c0c5ba7`, not streamed | last | on | | | | | 166 | 22 | |

The reply headers came at 1.9 to 5.0 s in each run. With search on, Claude writes no JSON until its last code step and its thinking end. The first item then came at 80 to 89 percent of the total time. After it, the items came about one per second for 20 to 22 s. Streaming thus turns the last 20 s into progress, but the wait before the first item stays.

Box order: with `box` last, the box closed 0 to 61 ms before its item. With `box` second, the box came 0.7 s (search on) and 1.3 s (search off) before its item. The model wrote `box` where the schema put it. Each order had one full run with search, so this is a small sample. box-second-1 made 3 searches and box-last-1 made 2, so their costs do not compare the two orders.

The spot pass: spot-1 had no tools. It found 22 items with boxes, with the first box at 4.1 s, for $0.035. The spike joined its items to the items of the priced runs by box overlap. 17 of 22 items matched at an IoU (intersection over union: the overlap of two boxes, from 0 to 1) of 0.5 or more. The median IoU was 0.78. The spot estimates were high. The middle of each spot range was a median 1.43 times the searched middle in box-last-1, and 1.33 times in box-second-1.

### The stall

In 4 runs, the model started two or three code steps at the same moment. Each step called `web_search` once. In each of these runs, one or two steps printed `{"status": "detection_timeout", "error": "Detection timed out after 90.0s"}` and ended about 96 s after they started. The model then ran the search again.

| Run | Code steps at the start | Result |
|---|---|---|
| scene `5c0c5ba7` | 2 at once | 1 step timed out |
| box-last-1 | 2 at once, near 21 s | 1 step timed out, at 117.9 s |
| box-last-2 | 2 at once, near 27 s | 1 step timed out, at 123.8 s |
| route, live run 1 | 3 at once, 22.9 to 24.3 s | 2 steps timed out, at 120.4 s, and no item before the 180 s limit |
| box-second-1 | 1, with 3 searches | no stall, searches done at 35.0 s |
| stop-1 | 1, with 3 searches | no stall, searches done at 30.1 s |

The pattern fits all 6 runs, but 6 runs do not prove a cause. The spike did not find what the API detects in these steps. Without the stall, the first item came at 57 and 90 s. With it, the first item came at 143 and 159 s, or not at all.

## 3. Stream events for the UI log

`StreamRoute.res` turns the Claude stream into SSE events (Server-Sent Events: named text events in one HTTP reply). Most events carry `t`, the milliseconds since the request started.

| UI log line | Route event and its data | From the Claude stream |
|---|---|---|
| Photo sent | `photo-received`: bytes, width, height | none, the brain read the photo |
| Claude started | `claude-started`: inputTokens | `message_start` |
| Thinking | `thinking` | a thinking block starts |
| Search step started | `tool-run`: id, name | a `server_tool_use` block for `code_execution` starts |
| Search started | `search-started`: id, query | a `server_tool_use` block for `web_search` starts |
| Search done, N results | `search-done`: id, count | a `web_search_tool_result` with results |
| Search failed | `search-failed`: id, errorCode | a `web_search_tool_result` with an error |
| Step done or timed out | `tool-done`: id, name, status | a `code_execution_tool_result` |
| (box on the photo) | `box`: index, box | text deltas, the `box` array closed |
| First item, then each item | `item`: index, item | text deltas, the item object closed |
| Done, with tokens and cost | `done`: claudeMs, inputTokens, outputTokens, webSearches, usd | `message_delta`, then `message_stop` |
| (eBay numbers) | `scene`: the same reply as `POST /api/scene` | none, code merges eBay after Claude |
| Error | `error`: message | an API error, the 180 s limit, or an item that does not decode |
| (none, the phone left) | `stop` | none, the phone closed the connection |

Three facts change the UI design:

1. `search-started` is not live. The stream shows a search when its code step ends, 10 to 25 ms before the result. The live signal is `tool-run`.
2. In a stall, the phone gets `tool-run`, then only heartbeats for about 96 s. The API sends `ping` every 30 s in a long step. The route sends its own heartbeat comment every 10 s.
3. Thinking blocks carry no text. The log can say "Thinking", but it cannot show what Claude thinks.

## 4. Stop

The route makes one `AbortController` for each request (`src/stream/StreamRoute.res:123`). If the reply closes before its end, the route aborts it. `ClaudeStream.run` gives `fetch` the signal `AbortSignal.any([timeout, stop])` (`src/stream/ClaudeStream.res:140`). One signal thus covers Stop and the 180 s limit.

The evidence:

- stop-1, runner, live: Stop came at the first item, at 56.8 s. The stream ended 13 ms later, and the brain kept the item.
- `StreamRouteTest`, with a stub API: the client closed, and the stub saw its request close within 2 s. The log got a `stopped` line with the items found.
- Route, live run 2, through the tailnet: the client closed after the first `tool-run`, at 18.1 s. The brain logged `stopped: true` at 18.09 s, with 0 items.
- Route, fixture, through the tailnet: one Chromium stream dropped at 37.6 s. The brain logged `stopped: true` and kept 2 items.

Node 26.0.0 with undici 8.0.2 uses HTTP/2 to the API. An abort resets one stream and keeps the pooled connection. The connection stayed open for 4.4 s after the close, as HTTP/2 expects. The spike did not see the reset on the wire.

Four gaps remain in the log:

- A stopped or timed-out scene has no cost. The stream sends usage only at its end, in `message_delta`. Before that, the brain knows only the input tokens from `message_start`. The runner shows $0.017 for box-last-2 and stop-1, but that is the input tokens only.
- A timed-out stream writes no line to `data/scenes.jsonl`. Live run 1 left no line.
- A stopped scene writes no raw events file.
- A dropped connection looks the same as Stop. A short loss of signal on the phone cancels the Claude call.

## 5. Transport to the PWA

The PWA sends the photo in a `fetch` POST and reads `response.body` as SSE text. `EventSource` cannot send a POST body, so it does not fit. The route sends `content-type: text/event-stream; charset=utf-8`, `cache-control: no-cache, no-transform` and `x-accel-buffering: no`.

`tailscale serve` proxies `https://dwights-macbook-pro.tail128d00.ts.net/` to `http://127.0.0.1:8787`, on the tailnet only, with no Funnel. The spike did not change its configuration.

The transport runs used fixture mode, with 500 ms between the events of the fixture:

| Client | Path | Result |
|---|---|---|
| curl | direct and tailnet, at the same time | Each tailnet event came 30 to 130 ms after the same event on the direct path. The proxy does not buffer. |
| Safari, iOS 26.3 Simulator | tailnet | All events came live. The stream ended at 44.3 s. See `docs/shots/stream-check-safari.png`. |
| Chromium 145, headless | tailnet, two pages at the same time | Both pages got all events and ended at 43.8 s. |
| Chromium 145, headless | tailnet, one page | It dropped at 37.6 s, while a simulator booted. The rerun above did not repeat it. |

The browser check used a throwaway JavaScript page that is not in git.

## Recommendation

1. Build the scan UI on `POST /api/scene/stream`. Read it with `fetch` and a body reader.
2. Show search progress at `tool-run`. Do not wait for `search-started`.
3. Remove the stall before the UI build. Do a docs check before each fix, then measure the fix on this scene:
   - Tell the model to put all its searches in one code step.
   - If the docs show that `web_search_20250305` runs no code steps, try it on Sonnet 5.
   - Try `tool_choice` `{type: "auto", disable_parallel_tool_use: true}`. Never use a forced `tool_choice`, because it returns a 400 on Opus 5.5.
4. Add a spot pass: a call with no tools that asks only for names and boxes. Start it at the same time as the priced pass.
5. Do not ask the spot pass for prices. Its estimates in spot-1 were 1.3 to 1.4 times the searched ones.
6. Join the two passes by box overlap. Decide what the UI shows for the 5 in 22 items with no match.
7. Move `box` to second place in the schema. Each box then comes about 1 s before its item.
8. Log stopped and timed-out scenes with their items. Mark their cost as not known.
9. Decide what a dropped connection does. Today, a drop cancels the scene.

## Hard rules

| Rule | How the spike keeps it |
|---|---|
| eBay numbers never reach the model | The route sends `scene` after `done`, and code merges eBay after Claude. `GuardTest` makes sure that the streamed body is the plain body plus `stream: true`. |
| Web search blocks ebay.com | The streamed body keeps `blocked_domains: ["ebay.com"]`. The spot pass has no tools. |
| Secrets come from the environment only | The key comes from `~/.config/reflip/env` through `--env-file-if-exists`. No log or evidence file holds it. |
| Bind to 127.0.0.1, never Funnel | The brain listened on `127.0.0.1:8787`. `tailscale serve` is on the tailnet only. |
| ReScript 12, TEA, no escape hatches | `SceneStream.res` is a model with an `update`. The new code has no `%raw` and no `Obj.magic`. |
| Decode JSON at the edge | `ClaudeEvents.res` decodes each stream event with `@glennsl/rescript-json-combinators`. |

## Not tested

- Safari on a real iPhone, on cellular, through the tailnet. The spike used the iOS 26.3 Simulator.
- A PWA page in the background on iOS.
- What Anthropic bills for a stopped or timed-out call.
- The HTTP/2 stream reset on the wire.
- A live run through the route to its `scene` event. Both live route runs ended early. Fixture runs covered the rest of the route.
- The `box` event through the route. The synthetic fixture has no boxes. The runner showed box events from the same `SceneStream` code.
- The spot estimates against real sold prices.

## Files

| Path | What it holds |
|---|---|
| `src/stream/Sse.res` | The SSE parser and encoder |
| `src/stream/ItemScanner.res` | The scanner for the partial JSON |
| `src/stream/ClaudeEvents.res` | The decoder for each Claude stream event |
| `src/stream/SceneStream.res` | The model and `update` from stream events to log events |
| `src/stream/ClaudeStream.res` | The network edge: `fetch`, the stream read, Stop, the time limit, the fixture replay |
| `src/stream/StreamRoute.res` | `POST /api/scene/stream` |
| `src/spike/StreamSpike.res` | The measurement runner, `npm run spike:stream` |
| `tests/fixtures/claude-stream.sse` | The synthetic stream for fixture mode and the tests |
| `docs/stream-spike/` | The run summaries, the transport logs, and two gzipped raw event files |

To measure again, give the runner the photo of a scene:

```sh
npm run spike:stream -- --photo PATH --label box-last-1 --schema box-last
npm run spike:stream -- --photo PATH --label spot-1 --schema box-second --search off
npm run spike:stream -- --photo PATH --label stop-1 --stop-after-first-item
```

Each run writes `data/spike/<label>.events.jsonl` and adds a line to `data/spike/runs.jsonl`. A live run cost $0.03 to $0.26. The known costs of this spike add up to $0.46. Four live runs ended early, so their cost is not known.
