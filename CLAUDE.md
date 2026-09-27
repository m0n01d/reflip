# reflip

## Shared conventions

Workspace-wide rules live in the private repo [`m0n01d/claude-conventions`](https://github.com/m0n01d/claude-conventions). On the Mac they load through `~/code/CLAUDE.md`. A cloud sandbox does not see that file. Fetch it first there:

```sh
gh repo clone m0n01d/claude-conventions /tmp/conventions 2>/dev/null || git clone https://github.com/m0n01d/claude-conventions /tmp/conventions
cat /tmp/conventions/CLAUDE.md
```

If the clone fails, keep going with this file. The rules that matter most for this repo are inlined below.

## What reflip is

reflip is the M0 spike of Flip Scout. Dwight named it reflip. The spec lives at [`m0n01d/app-ideas`](https://github.com/m0n01d/app-ideas), file `ideas/flip-scout.md`. Stage: building.

Flip Scout values items for resale from a photo or a marketplace listing. This spike answers one question. When Claude looks at a photo with vision and web search, what does one photo cost, in dollars and in seconds?

Part A is the brain. It is a ReScript 12 server on Node with one scene endpoint, recorded fixtures, and tests. Part B is the phone page. It is a ReScript 12 PWA that takes a photo and shows the reply from the brain. Both parts are built and live in this repo.

## Origin

The idea's origin is [wesbos/yard-sale](https://github.com/wesbos/yard-sale), by Wes Bos. That repo has no license, so we reuse its ideas, not its code or its prompt text. `SystemPrompt.res` is our own words. `EbayClient.res` copies no code from `~/code/yard-sale/worker/ebay.ts`. It only checks field names against that file.

## The numbers M0 set

Checked 2026-09-24 against `platform.claude.com/docs/en/about-claude/pricing` and the claude-api skill. Re-check before this drifts far from that date.

| Model id | Input $/MTok | Output $/MTok | Cache read multiplier | Web search tool type |
|---|---|---|---|---|
| `claude-opus-5-5` | 4 | 20 | 0.05x | `web_search_20260209` |
| `claude-sonnet-5` (default) | 2 | 10 | 0.1x | `web_search_20260209` |
| `claude-haiku-4-5` | 1 | 5 | 0.1x | `web_search_20250305` only |

- A 5-minute cache write costs 1.25x the input price, on every model above.
- A web search costs a flat $0.01. Its result text also bills as input tokens, on top of that flat fee.
- An image bills at about ceil(w/28) times ceil(h/28) tokens. Haiku 4.5 downsizes an image above a 1568px long edge. Opus 5.5 and Sonnet 5 downsize above 2576px.
- Structured output uses `output_config.format`, not the old `output_format` field. Its shape is `{type: "json_schema", schema: {...}}`.
- Never use forced `tool_choice`. It returns a 400 on Opus 5.5.
- The web search tool sets `allowed_callers: ["direct"]`, so Claude never searches from a code step. On Sonnet 5, parallel code steps stalled for about 96 s. `disable_parallel_tool_use` returns a 400 with code-step search. See `docs/stall-fix.md`.

`Pricing.res` holds this table in code. `PricingTest.res` checks it against a hand-computed value.

The first M1 experiment measured 10 real scenes on Sonnet 5 on 2026-09-24. Its record is in `docs/m1-first-experiment.md`.

## Hard design rules

1. eBay numbers never reach the model. The order is: call Claude first, then query eBay for each item, then merge the two in code. `GuardTest.res` checks this by building a real Claude request and searching its JSON for eBay fixture titles and prices.
2. The web search tool blocks ebay.com, with `blocked_domains: ["ebay.com"]`.
3. Secrets come from the environment only: `ANTHROPIC_API_KEY`, `EBAY_CLIENT_ID`, `EBAY_CLIENT_SECRET`, `GMAIL_USER`, `GMAIL_APP_PASSWORD`. `npm start` loads `~/.config/reflip/env` with Node's `--env-file-if-exists` flag. Never write a secret to the repo or to a log.
4. The server binds to `127.0.0.1` only. `tailscale serve` proxies HTTPS to it from the tailnet. Never Funnel.
5. `FIXTURES=1` forces fixture mode: both the Claude call and the eBay calls read from `tests/fixtures/` instead of the network. Outside fixture mode, a missing eBay key sets each item's `ebay` field to null and fills the reply's `ebayNote` field with why. A missing Anthropic key, without `FIXTURES=1`, returns a 503.

## How it fits together

- `src/bindings/`: typed externals for Node (`node:fs`, `node:http`, `node:path`, `node:os`, `node:crypto`, `process.env`) and for the global `fetch`.
- `src/Json.res`: decode and encode helpers over the built-in `JSON` module. Every decode returns an option, never a cast.
- `src/Types.res`: the shared domain types and the HTTP reply's JSON encoder.
- `src/Shared.res`: the model variant, the model ids and labels, and the `sceneReply` decoder. It has no Node imports, so both the server and the page use it. Neither side copies a model id string.
- `src/Pricing.res`, `src/Stats.res`: the cost formula and the price-percentile math, both pure and both tested.
- `src/ImageSize.res`: the reference resize function from the Claude vision guide, and the resolution tier of each model. It gives the size of the photo that Claude sees.
- `src/JpegSize.res`: reads the width and the height of the uploaded JPEG from its header. The reply sends them back as `imageWidth` and `imageHeight`.
- `src/Box.res`: decodes the `[x1, y1, x2, y2]` box of an item, clamps it to the photo, and rescales it when Claude saw a resized photo (Haiku 4.5).
- `src/SystemPrompt.res`: our own prompt text and the JSON schema for structured output.
- `src/ClaudeClient.res`: builds the Claude request, decodes its reply, and retries once without `output_config` on a 400 that names it. It stops a call after `timeoutMs` (180 s), and the scene route then returns a 504 with a JSON error.
- `src/EbayClient.res`: the client-credentials token (cached until it expires), the Browse API search, and the stats decode.
- `src/SceneLog.res`: appends one JSON line per scene to `data/scenes.jsonl`, and writes the raw Claude response to `data/raw/<sceneId>.json`. `data/` is gitignored.
- `src/Server.res`: the routes are `GET /`, `POST /api/scene`, `POST /api/scene/stream`, `POST /api/scene/:id/rtt`, `POST /api/scene/:id/stop`, `GET /api/scene/:id/events`, `GET /api/scenes/:id/photo`, and the haul routes `POST /api/hauls`, `POST /api/hauls/:id/scenes`, `GET /api/hauls/:id` and `POST /api/hauls/:id/done`. `GET` also serves any file under `dist/`. A guard blocks a path that leaves that folder. The rtt route logs `resizeMs` next to `rttMs`. `POST /api/scene/:id/stop` ends a running scene on purpose. `GET /api/scene/:id/events?from=<n>` replays a scene's buffered events and then follows it live, through `SceneRegistry`. The photo route serves the stored JPEG for one scene, guarded the same way as the `dist/` files.
- `src/Main.res`: the entry point `npm start` runs.
- Haul mode, per `docs/spec-haul-mode.md`: `Config.res` reads the environment. `Store.res` is the SQLite store in `data/reflip.db`. `HaulWorker.res` runs the Claude calls in the background. `HaulStatus.res` builds the reply of `GET /api/hauls/:id`.
- The haul email: `Digest.res` builds the subject and the bodies. `Thumb.res` makes the thumbnails with `sips`. `Crop.res` crops one gem from its photo with `sips`, with a 10% margin, at most 240 px on the long edge. The digest has one section for each photo: the photo once, then a crop for each gem. `scripts/eml-preview.py` turns an outbox `.eml` into one HTML file, for a look in a browser. `Email.res` builds the MIME message and sends it through Gmail SMTP with `nodemailer`. `HaulEmail.res` chooses between a send and the outbox. `EmailCheck.res` is `npm run email:check`, which logs in and sends nothing.
- `src/stream/`: the streaming scene route, per `docs/stream-spike.md`. `Sse.res` parses and encodes SSE. `ItemScanner.res` finds each item in the partial JSON. `ClaudeEvents.res` decodes each Claude stream event. `SceneStream.res` is the model and `update` from Claude events to log events. `ClaudeStream.res` is the network edge, with Stop and the time limit. `FixtureReplay.res` replays a recorded event log at real speed, for fixture mode and for `src/spike/`. `SpotPass.res` is the spot pass: a second, toolless Claude call with its own model and its own network edge. `SceneRegistry.res` buffers and broadcasts one scene's events, so a reconnect replays them. `StreamRoute.res` is `POST /api/scene/stream`, and it runs the spot pass next to the priced call.
- `src/spike/StreamSpike.res`: the measurement runner, `npm run spike:stream`. It writes to `data/spike/`.
- `src/web/`: the phone page. `Index.res` mounts it. `App.res` holds the view and the side effects. `AppState.res` holds the pure model, the `msg` type, and `update`. `Resize.res` scales and encodes the photo on a canvas. `Api.res` calls `/api/scene` and posts the round-trip time. `WebApi.res` holds the typed DOM and canvas bindings.

## Time-travel debugger (rewind)

- The rewind panel runs in dev builds only. `DevFlag.viteDev` binds Vite's own `import.meta.env.DEV` flag.
- `App.make` renders `rewind.model`, not a plain `useReducer` state. While paused on a past entry, the screen shows that past state.
- Effects and refs must read `rewind.live`, not `rewind.model`. A past model once stopped and aborted a live scan. Two effects had this bug, H1 and H2, fixed on 2026-09-25.
- Read `rewind.live` in any new effect or ref that touches the network or a live handle.
- The library is `github:m0n01d/rewind`. The repo became public on 2026-09-25, so a cloud session installs it with no GitHub key. npm downloads it as a tarball from `codeload.github.com`, so the `git+ssh` URL in the lockfile does not need a key.
- The panel hides its Export and Import buttons. reflip calls `Rewind.use` with no `~codec`. A live click-path check on 2026-09-25 confirmed both buttons stay off the panel.

## How to run

```sh
npm install
npm run build
npm test
FIXTURES=1 PORT=8787 npm start
```

`npm run build` builds the ReScript, then the Vite bundle, into `dist/`. After that, `npm start` serves the page at `http://127.0.0.1:8787/`.

The Node version comes from `.tool-versions`, which asdf reads. The file lists 26.0.0, then 22.16.0, and asdf runs the first one that is installed. The stream spike ran on 26.0.0 (`docs/stream-spike.md`). The Mac mini has no 26.0.0, so it runs 22.16.0. The store imports `node:sqlite`. That module needs no flag on Node 22.13.0 or later in the 22 line, or on 23.4.0 or later. Checked 2026-09-27 against `nodejs.org/api/sqlite.html`. The `engines` field in `package.json` holds that range. Node 23.0.0 is the global asdf default on the Mac mini, and it is outside that range. On it, `npm start` stops at once with `ERR_UNKNOWN_BUILTIN_MODULE: node:sqlite`.

With the server running, in another shell:

```sh
curl -s -X POST --data-binary @tests/fixtures/table.jpg -H 'content-type: image/jpeg' http://127.0.0.1:8787/api/scene
```

To develop the page with fast reloads, run the brain in one shell and Vite in another. Use `FIXTURES=1 PORT=8787 npm start` for the brain and `npm run dev:web` for Vite. Vite proxies `/api` to the brain on port 8787. Vite does not serve `/api` itself.

`npm start` uses Node's `--env-file-if-exists` flag. If `~/.config/reflip/env` exists, that flag loads it. If not, `npm start` skips it and keeps going. Put each secret on its own `KEY=value` line there. No secret goes in this repo.

To test the page from a phone on the tailnet, run `npm run build`, then `npm run tailnet`, then `npm start`. `npm run tailnet` points `tailscale serve` at the brain port and prints the HTTPS URL. The port is `PORT`, or 8787 if `PORT` is not set. The proxy is on the tailnet only, and it stays on after the script exits. The script finds the `tailscale` CLI on `PATH` or in `/Applications/Tailscale.app`. If Tailscale is off, the script prints `Tailscale is stopped.` and exits with code 1.

The tailnet needs MagicDNS and HTTPS certificates. Both are on in the Tailscale admin console. The first request can take about 25 s, because Tailscale gets the TLS certificate then. The brain does not restart by itself. If nothing listens on the port, the proxy returns an error. To stop the proxy, run `tailscale serve reset`. That command clears every serve rule on the Mac. To make sure that the brain listens on `127.0.0.1` only, run `lsof -nP -iTCP:8787 -sTCP:LISTEN`. The output must show `127.0.0.1:8787`, not `*:8787`.

## Use `resq` when editing the `.res` files here

`resq` reads and edits ReScript structurally. Prefer it over reading a whole file and hand-splicing text. Run `resq guide` for the full command reference.

```sh
resq list src/Server.res
resq get src/ClaudeClient.res buildRequestBody
resq refs src/Types.res usage
resq patch src/Stats.res percentile --old 'old code' --new 'new code'
```

Writes fail closed: resq refuses a file that already has parse errors, re-parses its own output, and leaves the file byte-identical on any failure.

## Bootstrapping resq in a fresh environment

A cloud sandbox starts with nothing installed. This section covers that case. On claude.ai/code, or from the phone app, you get a container with only this repo. The workspace-level `~/code/CLAUDE.md` is not there, so this has to live here too.

```sh
curl -fsSL https://raw.githubusercontent.com/m0n01d/resq/main/scripts/install.sh | sh
export PATH="$HOME/.cargo/bin:$PATH"
```

[`m0n01d/resq`](https://github.com/m0n01d/resq) is public, so this needs no credentials. The script is idempotent. If `cargo` is missing, the script installs rustup itself.

If resq cannot be installed, nothing here breaks. Just edit the `.res` files directly. resq is a convenience, not a dependency.

## Testing

`npm test` builds, then runs `src/tests/AllTests.res.mjs`. Each test file uses `node:assert` through `src/tests/TestKit.res`, the same shape as dippa's own test kit. A failing assertion throws, so a red test fails the process exit code.

`tests/fixtures/` holds the recorded shapes: a Claude Messages API response with three items, one eBay Browse API response per item, and a small generated JPEG. See that folder's own `README.md`. Some files came from real Claude calls. `tests/fixtures/demo/claude-stream.events.jsonl.gz` records a priced call from before the stall fix. The recording is 112.6 s long. `tests/fixtures/demo/claude-spot.events.jsonl.gz` records one live spot pass. `tests/fixtures/spot/claude-spot.events.jsonl` is that spot recording with changed timings.

`scripts/haul-smoke.mjs` is a repeatable smoke test of the phone haul view. It uses fixture mode and drives the page with dev-browser. The script builds the app, then starts the server on a free port. The server gets a throwaway data directory and no live secrets. It starts a haul, adds the fixture photo five times, and waits for the haul to finish. Then it opens, switches, and closes each gem card, and taps one sold link. The script blocks ebay.com, so that tap never reaches the network.

The script never sends an email. It writes the digest to a throwaway outbox instead, because `FIXTURES=1` always uses the outbox. The flags are:

- `--n <count>`: the number of photos. Default: 5.
- `--out <dir>`: the output directory. Default: `data/smoke/<UTC stamp>/`.
- `--skip-build`: skip the build step.
- `--headed`: show the browser window. Default: headless.
- `--timeout <seconds>`: the dev-browser time limit. Default: 180.

The script prints one JSON result line and puts its screenshots in the output directory. It exits with 0 only when every step passes. It uses its own dev-browser instance, `reflip-smoke`, and closes its pages at the end, also after a failure. It needs `dev-browser` on the machine (`npm install -g dev-browser`, then `dev-browser install`).

```sh
node scripts/haul-smoke.mjs
```

`scripts/place-check.mjs` is a repeatable check of the haul view's place line: a saved gps fix, a late haul id, the outbox surviving a reload, a denied prompt, a failed-then-retried prompt, the outbox surviving a reload after Done and the email note, and a privacy check of the brain's own log. Run it the same way, `node scripts/place-check.mjs`. Like `haul-smoke.mjs`, it never sends an email, because `FIXTURES=1` always uses the outbox.

## Live keys

`~/.config/reflip/env` has all five secrets since 2026-09-25. The first live haul ran that day: 3 photos, $0.42 in Claude, one email sent. `EbayClient.statsFor` returned live eBay stats for the three fixture items the same day.

The eBay keys must come from the Production keyset on developer.ebay.com. The App ID contains `-PRD-` and the Cert ID starts with `PRD-`. `api.ebay.com` gives a 401 `invalid_client` to a Sandbox key (`SBX`). It also gives that 401 to a new Production keyset until you opt out of marketplace account deletion notifications. reflip keeps no eBay user data, so the opt-out applies.

## What is not built yet

- M1 lite, per [`docs/spec-lite-m1.md`](docs/spec-lite-m1.md): the paid and sold entry on the phone page and the calibration readout. `docs/spec-budget.md` replaces its Finds view, so the M1 lite spec must change to match before the build. The first experiment is in `docs/m1-first-experiment.md`.
- The Mac mini as the always-on host, with its own clone, its own `~/.config/reflip/env`, a way to keep the brain running, and its own `tailscale serve`. The MacBook Pro already runs one, per `docs/stream-spike.md`.
- The Chrome extension side of Flip Scout. That is later spec work, not this spike.
