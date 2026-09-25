# Stall fix

Date: 2026-09-25. Branch: `claude/stall-fix`. Model: `claude-sonnet-5`.

`docs/stream-spike.md`, recommendation 3, is to remove the stall before the UI build, with a docs check before each candidate fix, then a measurement. This report is that docs check and that measurement.

This branch sets `allowed_callers: ["direct"]` on the web search tool. Claude then searches with no code step, so the 90-second limit on a code step cannot apply. On one photo, the three direct runs that searched reached the first item in 17 to 51 s. The two control runs took 60 to 89 s. The direct runs cost $0.14 to $0.17, and the control runs cost $0.20 to $0.27. The stall did not happen in the control runs, so no run today proves the fix.

## The fault

`docs/stream-spike.md`, section "The stall", has the first report of this fault.

When it has the tool `web_search_20260209`, Sonnet 5 searches from inside code execution steps. In four runs, the model started two or three code steps at the same time. One or two of those steps printed this error, and stopped about 96 s after they started:

```
{"status": "detection_timeout", "error": "Detection timed out after 90.0s"}
```

## Docs check

A `claude-code-guide` agent (haiku) fetched three pages on 2026-09-25. The conductor read the lines behind each claim again.

Pages read:

- `platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool`
- `platform.claude.com/docs/en/agents-and-tools/tool-use/code-execution-tool`
- `platform.claude.com/docs/en/agents-and-tools/tool-use/programmatic-tool-calling`

Found:

1. On `web_search_20260209` and later, `allowed_callers` defaults to `["code_execution_20260120"]`. Search then runs from code. The docs call this "dynamic filtering".
2. `allowed_callers: ["direct"]` calls search directly, with no dynamic filtering.
3. Every web search tool version accepts `allowed_callers`.
4. In programmatic tool calling, each Python cell in code execution has a 90-second wall-clock limit.

Not found:

- The docs do not name `detection_timeout`. The 90.0s in the error text matches item 4 above.
- The docs do not say how `disable_parallel_tool_use` acts with a server tool. The live API answered this instead, in the `noparallel` candidate below.

## Field check

This check ran on 2026-09-25, against `POST /v1/messages/count_tokens`. This endpoint runs no model. This report does not confirm a price for it.

Every call in this check used the tool `web_search`, with `max_uses: 3` and `blocked_domains: ["ebay.com"]`.

| Model | Web search tool | `allowed_callers` | HTTP status |
|---|---|---|---|
| `claude-haiku-4-5` | `web_search_20250305` | `["direct"]` | 200 |
| `claude-haiku-4-5` | `web_search_20250305` | (none) | 200 |
| `claude-haiku-4-5` | `web_search_20250305` | `["bogus_caller"]` | 400 |
| `claude-opus-5-5` | `web_search_20260209` | `["direct"]` | 200 |

The 400 result is a negative control. It returned this error:

```
allowed_callers.0: Input should be 'direct', 'code_execution_20250825', 'code_execution_20260120' or 'code_execution_20260521'
```

This shows that the endpoint reads the `allowed_callers` field, and rejects a bad value. The live runs below cover `claude-sonnet-5` with `direct`.

## Candidates

This report tested four candidate fixes, plus a control. Each candidate is a flag on the stream-spike runner, `src/spike/StreamSpike.res`, at commit `9cafb9e`.

| Candidate | Flag | What it does |
|---|---|---|
| `onestep` | `--prompt-onestep` | Adds a system line that asks for every web search in one code step, and no second step while one step runs. |
| `ws0305` | `--search-tool web_search_20250305` | Uses the older search tool. This tool searches directly. |
| `direct` | `--direct-search` | Uses `web_search_20260209` with `allowed_callers: ["direct"]`. |
| `noparallel` | `--no-parallel` | Sets `tool_choice` to `{type: "auto", disable_parallel_tool_use: true}`. |
| `default` | (no flag) | The control. |

The `noparallel` request failed, with HTTP 400 and this error:

```
tool_choice.disable_parallel_tool_use: true cannot be used with programmatic tool calling
```

Its request ID is `req_011CfQFSUsagTBZf5GvfVUxZ`, and its cost is $0. This candidate is dead.

Every run in this test used `claude-sonnet-5`, the schema `box-second`, and `blocked_domains: ["ebay.com"]`. Every run used the same photo as `docs/stream-spike.md`: `s01-1568-sent.jpg`, at 1568 x 1176 pixels. That photo is gitignored, and it is never in the repository. The baseline is `box-second-1`, from `docs/stream-spike.md`. Every run in this test ran on 2026-09-25.

## Results

`scripts/compare_runs.py` built the table below. The run summaries behind it are at `docs/stall-fix/<label>.out`.

| label | code steps | detection_timeout | longest step | web searches | first item | done | items | usd | outcome | IoU>=0.5 | median IoU |
|---|---|---|---|---|---|---|---|---|---|---|---|
| box-second-1 (baseline) | 4 | 0 | 8143ms | 3 | 90188ms | 112608ms | 22 | $0.2565 | completed | 22 | 1.00 |
| default-2 | 4 | 0 | 7458ms | 2 | 59695ms | 76572ms | 18 | $0.2006 | completed | 15 | 0.83 |
| default-3 | 5 | 0 | 7393ms | 3 | 89176ms | 109644ms | 27 | $0.2696 | completed | 20 | 0.80 |
| onestep-1 | 2 | 0 | 8607ms | 3 | 48742ms | 74144ms | 24 | $0.1511 | completed | 16 | 0.77 |
| onestep-2 | 4 | 0 | 8694ms | 3 | 76487ms | 98500ms | 23 | $0.2432 | completed | 19 | 0.83 |
| ws0305-1 | 0 | 0 | - | 2 | 35277ms | 57177ms | 21 | $0.1442 | completed | 18 | 0.84 |
| ws0305-2 | 0 | 0 | - | 2 | 26860ms | 49666ms | 22 | $0.1447 | completed | 17 | 0.79 |
| ws0305-3 | 0 | 0 | - | 2 | 28455ms | 50835ms | 20 | $0.1507 | completed | 13 | 0.88 |
| direct-1 | 0 | 0 | - | 2 | 51275ms | 75049ms | 25 | $0.1670 | completed | 18 | 0.77 |
| direct-2 | 0 | 0 | - | 0 | 28858ms | 50313ms | 23 | $0.0610 | completed | 17 | 0.83 |
| direct-3 | 0 | 0 | - | 2 | 39371ms | 73888ms | 23 | $0.1624 | completed | 18 | 0.80 |
| direct-4 | 0 | 0 | - | 2 | 16976ms | 40389ms | 21 | $0.1352 | completed | 14 | 0.86 |

`first item` and `done` show milliseconds from the start of the request. `IoU>=0.5` counts each item box that matches a baseline box at an IoU of 0.5 or more. IoU (intersection over union) is the overlap area divided by the union area. The match is one to one. `median IoU` is the median over those matched pairs.

For scale, two runs of `docs/stream-spike.md` (`box-last-1` against `box-second-1`) matched 18 boxes at a median IoU of 0.83. This is the normal spread between two runs.

The table below covers the runs that made no code step. It shows the gap from the last search result to the first item, and the output tokens:

| Run | Gap: last search to first item | Output tokens |
|---|---|---|
| ws0305-1 | 18 s | 4920 |
| ws0305-2 | 12 s | 4512 |
| ws0305-3 | 3 s | 4827 |
| direct-1 | 27 s | 6711 |
| direct-3 | 26 s | 6424 |
| direct-4 | 3 s | 3628 |

## What the results show

- The stall did not happen today. Neither control run started parallel code steps. No run printed `detection_timeout`. So no run today proves that a candidate removes the stall.
- The `ws0305` and `direct` candidates ran no code step. The 90-second limit applies only to a Python cell, so it cannot apply to them. Each fix removes the cause of the stall by design.
- Without `direct-2`, the `direct` and `ws0305` runs reached the first item in 17 to 51 seconds, at a cost of $0.135 to $0.167. The two control runs took 60 to 89 seconds, at a cost of $0.20 to $0.27. This test used one photo and few runs.
- `direct-2` made no search. The model chose not to search. Its time and cost do not compare to the runs that did search. Later runs must report their search count.
- The `direct` and `ws0305` runs overlap in speed and in the gap times above. The difference between them is noise.
- Matches at IoU 0.5 or more ranged from 13 to 18 for the no-code-step runs, and 15 to 20 for the control runs. The median IoU was 0.77 to 0.88 in every variant, near the 0.83 of the baseline pair. Item counts ranged from 20 to 25 for the no-code-step runs, and 18 to 27 for the control runs. This test had few runs. It shows no clear difference.
- The `onestep` candidate kept its code steps. `onestep-2` ran four code steps, although its prompt asked for one. This fix depends on the model obeying a prompt line. It was the slowest candidate on average.

## The choice

This branch sets `allowed_callers: ["direct"]` on the web search tool, in `ClaudeClient.buildRequestBody`.

Reasons:

1. The docs name this field for this purpose.
2. It keeps `web_search_20260209`. So `Pricing.res` and the model table in `CLAUDE.md` stay true.
3. It is one line inside the tool object, away from the lines that other branches edit.
4. It covers both the scene requests and the haul requests.
5. The field check above shows that Haiku 4.5 and Opus 5.5 also accept it.

Why not `ws0305`: it is an older tool version. Choosing it needs a change to the model table. It showed no measured gain in the results above.

## Other changes on this branch

Commits `ac015c5` and `abb3695` made these changes too:

- `box` now comes second in the item properties of `SystemPrompt.itemSchema`. Recommendation 7 of `docs/stream-spike.md` says each box then comes about 1 second before its item. This report did not measure that timing again. The `required` list did not change.
- `promptVersion` is now `scene-4`. The `main` branch already uses `scene-2` and `scene-3` for other prompt changes, so this prompt needs its own label. `haulPromptVersion` did not change, because the haul prompt and its schema did not change.
- The runner flag `--dynamic-filtering` removes `allowed_callers`, for a control run. The runner flag `--schema box-last` now moves `box` to the last position. The default schema is `box-second`, so a run with no flags sends the same body that the app sends. The run summary reads the callers from the request body.
- `GuardTest` checks `allowed_callers: ["direct"]` and `blocked_domains: ["ebay.com"]` on both the scene and haul request bodies. It also checks that each item's properties start with `name`, then `box`.
- `CLAUDE.md` has one new bullet, after the line about `tool_choice`.

## Merge notes

This check used `git merge-tree` on 2026-09-25.

- `origin/main`, at `5dd6d2a`: this branch conflicts with `main` in `CLAUDE.md`, `src/Server.res`, and `src/SystemPrompt.res`. `CLAUDE.md` and `src/Server.res` already conflict with `main` without this fix, because of `claude/stream-spike`. This fix adds two hunks in `src/SystemPrompt.res`. First, in the item properties: `main` added `size` before the old `box` block, at the end. Keep `size`, remove the old `box` block, and keep `box` after `name`. Second, for `promptVersion`: keep `"scene-4"`, and change the check in `src/tests/ScaleRefTest.res` from `"scene-3"` to `"scene-4"`.
- `origin/claude/haul-crops`, at `da3dc4d`: only `CLAUDE.md` conflicts, with or without this fix.
- `claude/haul-crops-crop`, at `16f5914`, local only: the same five files conflict, with or without this fix. The hunk in `src/ClaudeClient.res` is identical in both cases. This fix adds no new conflict.

## Cost

This test made 12 live requests, for a total of $1.83.

- Round 1: $0.4623
- Round 2: $0.6495
- Round 3: $0.5827
- `direct-4`: $0.1352

The `noparallel` request failed with a 400 error and cost $0. The four field-check requests went to the token count endpoint, which runs no model.

## Evidence

Each file in `docs/stall-fix/events/` is a gzip of a `data/spike/<label>.events.jsonl` file, for each label in the results table with a matching file. `data/spike/` is not in git, so these files are the only copy of the raw stream events in git.

`box-second-1` has no file in `data/spike/`. Its raw events are already gzipped, at `docs/stream-spike/events/box-second-1.events.jsonl.gz`.

Before staging, this check searched every file under `docs/stall-fix/`, plain text and gzip. It found no API key text (`sk-ant`) and no photo in base64 (`/9j/`).

## To measure again

A run with no flags now sends the same request that the app sends.

```sh
npm run --silent spike:stream -- --photo <photo.jpg> --label direct-5 > docs/stall-fix/direct-5.out 2>&1
npm run --silent spike:stream -- --photo <photo.jpg> --label control-4 --dynamic-filtering > docs/stall-fix/control-4.out 2>&1
python3 scripts/compare_runs.py --baseline box-second-1 docs/stream-spike/box-second-1.out docs/stream-spike/events/box-second-1.events.jsonl.gz --run direct-5 docs/stall-fix/direct-5.out data/spike/direct-5.events.jsonl
```

Each live run costs $0.03 to $0.27.

This report ran the compare command above with `direct-4` in place of `direct-5`, against the gzip files this report commits. The output matched the `direct-4` row of the results table:

```
| label | code steps | detection_timeout | longest step | web searches | first item | done | items | usd | outcome | IoU>=0.5 | median IoU |
|---|---|---|---|---|---|---|---|---|---|---|---|
| box-second-1 | 4 | 0 | 8143ms | 3 | 90188ms | 112608ms | 22 | $0.2565 | completed | 22 | 1.00 |
| direct-4 | 0 | 0 | - | 2 | 16976ms | 40389ms | 21 | $0.1352 | completed | 14 | 0.86 |
```

## Not confirmed

- Whether the chosen fix removes the stall. No run in this report reproduced the stall, so no run proves that a candidate removes it.
- A price for `POST /v1/messages/count_tokens`. This report did not confirm one at `platform.claude.com/docs/en/build-with-claude/token-counting`.
- How `disable_parallel_tool_use` acts with dynamic filtering, from the docs. The live API answered this instead, with a 400 error, in the `noparallel` candidate.
- The 1-second gap between a box and its item, from the move of `box` to second place. This report did not measure that gap again.
