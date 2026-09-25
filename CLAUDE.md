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

`Pricing.res` holds this table in code. `PricingTest.res` checks it against a hand-computed value.

## The numbers the first M1 experiment measured

Measured 2026-09-24 on a MacBook Pro (Mac17,2, Apple M5, macOS 27.0, Node 26.0.0), not on the Mac mini. The model was `claude-sonnet-5` at its default effort, with no eBay keys. dev-browser sent each photo through the page at `http://127.0.0.1:8787/`, so `Resize.res` scaled it to a long edge of 1568px.

The 10 photos are yard-sale and car-boot-sale scenes from Wikimedia Commons, not Dwight's own tables. Each one had a long edge of 1568px or more before the resize. `~/Pictures/reflip-m1/SOURCES.tsv` on that Mac lists the source page and the license of each photo. Dwight's own photos come next, as a second set of rows.

For this run, a local edit raised the Claude fetch timeout in `ClaudeClient.res` from 60 s to 300 s. Nobody committed that edit. With the 60 s timeout, the first scene failed with a 500, and 2 of the 10 scenes took more than 60 s.

| Photo | Items | Cost $ | Claude s | Input tokens | Output tokens | Searches | Search share | RTT s | Resize ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| s01 | 19 | 0.233 | 85.8 | 61,689 | 7,955 | 3 | 13% | 85.9 | 63 |
| s02 | 10 | 0.176 | 43.6 | 56,958 | 3,216 | 3 | 17% | 43.6 | 47 |
| s03 | 11 | 0.136 | 41.6 | 38,750 | 2,800 | 3 | 22% | 41.6 | 85 |
| s04 | 9 | 0.171 | 49.5 | 51,278 | 3,832 | 3 | 18% | 49.5 | 71 |
| s05 | 12 | 0.146 | 51.6 | 39,502 | 3,722 | 3 | 21% | 51.7 | 41 |
| s06 | 5 | 0.026 | 11.9 | 8,192 | 972 | 0 | 0% | 11.9 | 28 |
| s07 | 9 | 0.154 | 44.7 | 47,296 | 2,894 | 3 | 20% | 44.7 | 49 |
| s08 | 15 | 0.172 | 143.2 | 50,127 | 4,172 | 3 | 17% | 143.2 | 39 |
| s09 | 14 | 0.150 | 51.3 | 41,115 | 3,779 | 3 | 20% | 51.4 | 60 |
| s10 | 8 | 0.035 | 18.3 | 8,808 | 1,760 | 0 | 0% | 18.3 | 72 |
| Median | 10.5 | 0.152 | 47.1 | 44,206 | 3,469 | 3 | 18% | 47.1 | 54 |

Search share is `webSearches` × $0.01 ÷ cost, as the M1 spec defines it. The 10 scenes cost $1.40 in total. One more call timed out before the timeout edit. It is not in the log, and its cost is unknown.

The spec's proposed thresholds give these results on the medians:

- Search is 18% of the median cost by the spec's formula. That is less than half, so by that rule the two-pass search does not move up in Later.
- The formula counts only the $0.01 fee, but the search results also bill as input tokens. The 2 scenes with no search used about 8,500 input tokens. The 8 scenes with search used 38,750 to 61,689.
- If search causes that difference, search drives about two thirds of the cost of a median scene with search. This estimate comes from only 2 scenes with no search.
- The median scene cost $0.152 and took 47.1 s in Claude. Both are over the thresholds of $0.10 and 20 s. The next step is to measure a lower effort on Sonnet 5, before any change of model.

Input tokens were 50% to 65% of the cost of each scene, and no scene used the prompt cache. The round trip from the page was the Claude time plus less than 0.2 s.

The raw replies in `data/raw/` show no bad JSON. All 10 stopped with `end_turn` and parsed as valid JSON. No range was inverted or wider than 5 times its low end. The highest range was $120 to $300, for a wooden garden cart. Confidence was 0.20 to 0.60. Scene s01 used 7,955 output tokens for 19 items, close to the `max_tokens` limit of 8,192.

## Hard design rules

1. eBay numbers never reach the model. The order is: call Claude first, then query eBay for each item, then merge the two in code. `GuardTest.res` checks this by building a real Claude request and searching its JSON for eBay fixture titles and prices.
2. The web search tool blocks ebay.com, with `blocked_domains: ["ebay.com"]`.
3. Secrets come from the environment only: `ANTHROPIC_API_KEY`, `EBAY_CLIENT_ID`, `EBAY_CLIENT_SECRET`. `npm start` loads `~/.config/reflip/env` with Node's `--env-file-if-exists` flag. Never write a secret to the repo or to a log.
4. The server binds to `127.0.0.1` only. Later, `tailscale serve` proxies HTTPS to it from outside. Never Funnel.
5. `FIXTURES=1` forces fixture mode: both the Claude call and the eBay calls read from `tests/fixtures/` instead of the network. Outside fixture mode, a missing eBay key sets each item's `ebay` field to null and fills the reply's `ebayNote` field with why. A missing Anthropic key, without `FIXTURES=1`, returns a 503.

## How it fits together

- `src/bindings/`: typed externals for Node (`node:fs`, `node:http`, `node:path`, `node:os`, `node:crypto`, `process.env`) and for the global `fetch`.
- `src/Json.res`: decode and encode helpers over the built-in `JSON` module. Every decode returns an option, never a cast.
- `src/Types.res`: the shared domain types and the HTTP reply's JSON encoder.
- `src/Shared.res`: the model variant, the model ids and labels, and the `sceneReply` decoder. It has no Node imports, so both the server and the page use it. Neither side copies a model id string.
- `src/Pricing.res`, `src/Stats.res`: the cost formula and the price-percentile math, both pure and both tested.
- `src/SystemPrompt.res`: our own prompt text and the JSON schema for structured output.
- `src/ClaudeClient.res`: builds the Claude request, decodes its reply, and retries once without `output_config` on a 400 that names it.
- `src/EbayClient.res`: the client-credentials token (cached until it expires), the Browse API search, and the stats decode.
- `src/SceneLog.res`: appends one JSON line per scene to `data/scenes.jsonl`, and writes the raw Claude response to `data/raw/<sceneId>.json`. `data/` is gitignored.
- `src/Server.res`: the routes are `GET /`, `POST /api/scene`, and `POST /api/scene/:id/rtt`. `GET` also serves any file under `dist/`. A guard blocks a path that leaves that folder. The rtt route logs `resizeMs` next to `rttMs`.
- `src/Main.res`: the entry point `npm start` runs.
- `src/web/`: the phone page. `Index.res` mounts it. `App.res` holds the view and the side effects. `AppState.res` holds the pure model, the `msg` type, and `update`. `Resize.res` scales and encodes the photo on a canvas. `Api.res` calls `/api/scene` and posts the round-trip time. `WebApi.res` holds the typed DOM and canvas bindings.

## How to run

```sh
npm install
npm run build
npm test
FIXTURES=1 PORT=8787 npm start
```

`npm run build` builds the ReScript, then the Vite bundle, into `dist/`. After that, `npm start` serves the page at `http://127.0.0.1:8787/`.

With the server running, in another shell:

```sh
curl -s -X POST --data-binary @tests/fixtures/table.jpg -H 'content-type: image/jpeg' http://127.0.0.1:8787/api/scene
```

To develop the page with fast reloads, run the brain in one shell and Vite in another. Use `FIXTURES=1 PORT=8787 npm start` for the brain and `npm run dev:web` for Vite. Vite proxies `/api` to the brain on port 8787. Vite does not serve `/api` itself.

`npm start` uses Node's `--env-file-if-exists` flag. If `~/.config/reflip/env` exists, that flag loads it. If not, `npm start` skips it and keeps going. Put each secret on its own `KEY=value` line there. No secret goes in this repo.

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

`tests/fixtures/` holds the recorded shapes: a Claude Messages API response with three items, one eBay Browse API response per item, and a small generated JPEG. See that folder's own `README.md`. Nothing there came from a real API call.

## What is not built yet

- eBay keys in `~/.config/reflip/env`. eBay access is not approved. The MacBook Pro has an Anthropic key, and the first M1 experiment used it.
- A Claude fetch timeout that fits real scenes. `ClaudeClient.res` aborts after 60 s, but 2 of the 10 real scenes took longer.
- `tailscale serve` in front of this server.
- The haul-summary email and the Chrome extension side of Flip Scout. Those are later spec work, not this spike.
