# Fixtures

These files are synthetic. Nobody captured them from a real call.

We shaped `claude-scene.json` and `claude-haul.json` from the Messages API,
per the claude-api skill. `claude-haul.json` is the haul prompt's shape
(step 4): each item has a `where`, and the reply has a top-level
`otherCount`. Its third item's `estimateHighUsd` (15) sits under the
default $20 gem threshold on purpose, to prove the threshold is code, not
the prompt. We shaped `claude-stream.sse` by hand from the streaming
Messages API docs. It embeds the same 3 items as `claude-scene.json`, and
nobody streamed it from a real call. We shaped each `ebay-search-*.json`
from the eBay Browse API, per `~/code/yard-sale/worker/ebay.ts` and eBay's
own docs. `table.jpg` is a small generated image, not a real photo.

Per `docs/spec-scale-ref.md`, `claude-scene.json` has `quarterSeen: true`
at the top level, and each fixture's items mix a `size` value, an empty
`size`, and a missing `size` key, so a decode exercises all three cases.

`table.jpg` is 64x48 pixels. Each item in `claude-scene.json` has a `box`
in pixels of that image, so fixture mode shows boxes when you send
`table.jpg`. With any other photo, the boxes stay near its top-left corner.

## Timed replay

`FixtureReplay.res` reads a recorded Claude stream. It replays the stream
in real time. It does not send every event at once.

A recording is one file, `<base>.events.jsonl`, or its gzip form,
`<base>.events.jsonl.gz`. Each line is one JSON object, with fields `ms`,
`event`, and `data`. The `ms` field is the offset of the event from the
start of the recorded call.

`STREAM_FIXTURE_SPEED` sets the replay speed. FixtureReplay divides the
`ms` value of each event by this number. A speed of 10 plays the recording
10 times faster than real time. The default speed is 1. FixtureReplay
ignores a value of 0 or less, and uses speed 1 instead.

`tests/fixtures/replay/` holds a small recording for tests.
`tests/fixtures/demo/` holds a full recording, with about 22 items over
112 seconds.

Use this command to start the demo server at speed 10:

```sh
FIXTURES=1 FIXTURES_DIR=tests/fixtures/demo STREAM_FIXTURE_SPEED=10 PORT=8793 npm start
```

Then, in a second shell, send the test photo to the stream route:

```sh
curl -sN -X POST --data-binary @tests/fixtures/table.jpg -H 'content-type: image/jpeg' http://127.0.0.1:8793/api/scene/stream
```

If neither file exists, ClaudeStream uses `claude-stream.sse`. The route
used this fixture before this feature existed.
