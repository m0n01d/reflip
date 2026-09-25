// Timed replay of a recorded Claude SSE stream, for the scan UI's demo and
// for tests. tests/fixtures/<base>.events.jsonl, or its gzipped form, holds
// one recorded call: one JSON object per line, {"ms": <float, offset from
// the call's start>, "event": <SSE event name>, "data": <SSE data string>}
// -- the same shape src/spike/StreamSpike.res's eventLine writes. ms/event/
// data round-trip straight into an Sse.event, so a caller can feed a
// delivered event through the same Sse -> ClaudeEvents -> SceneStream
// pipeline ClaudeStream.res already uses for a live call.
//
// Package search (~/code/CLAUDE.md "Finding ReScript packages", checked
// 2026-09-25): decode uses @glennsl/rescript-json-combinators, already a
// project dependency (ClaudeEvents.res decodes the same way). No new
// package. Decompression is src/bindings/Zlib.res, a one-function typed
// binding to Node's zlib, per the house no-raw-calls rule.

module D = JsonCombinators.Json.Decode

// One recorded line. `evt` is exactly the record Sse.feed() would have
// produced for the live call this fixture was captured from.
type recorded = {ms: float, evt: Sse.event}

let decoder: D.t<recorded> = D.object(field => {
  let sseEvt: Sse.event = {
    event: field.required("event", D.string),
    data: field.required("data", D.string),
  }
  {ms: field.required("ms", D.float), evt: sseEvt}
})

// One line -> one recorded event. None on bad JSON or a shape mismatch,
// logged and skipped rather than failing the whole replay -- a single
// damaged line in a 1000+ line recording shouldn't sink the rest.
let decodeLine = (line: string): option<recorded> =>
  switch JsonCombinators.Json.parse(line) {
  | Error(msg) => {
      Console.error("FixtureReplay: bad JSON line: " ++ msg)
      None
    }
  | Ok(json) =>
    switch JsonCombinators.Json.decode(json, decoder) {
    | Ok(r) => Some(r)
    | Error(msg) => {
        Console.error("FixtureReplay: bad event line: " ++ msg)
        None
      }
    }
  }

// <fixturesDir>/<base>.events.jsonl, or its .gz form. None when neither
// exists, so a caller can fall back to another fixture path (ClaudeStream's
// claude-stream.sse today).
let findFile = (fixturesDir: string, base: string): option<string> => {
  let plain = Node.Path.join([fixturesDir, base ++ ".events.jsonl"])
  let gz = plain ++ ".gz"
  if Node.Fs.existsSync(plain) {
    Some(plain)
  } else if Node.Fs.existsSync(gz) {
    Some(gz)
  } else {
    None
  }
}

// Reads and decodes every line of a file found by findFile, in file order.
// A blank line (the usual trailing newline) is skipped without a warning.
let readEvents = (path: string): array<recorded> => {
  let text = String.endsWith(path, ".gz")
    ? Zlib.gunzipSync(Node.Fs.readFileBuffer(path))->Node.Buffer.toStringWithEncoding("utf8")
    : Node.Fs.readFileUtf8(path, "utf8")
  text
  ->String.split("\n")
  ->Array.filter(line => line != "")
  ->Array.filterMap(decodeLine)
}

// Resolves after ms, or as soon as `stop` fires its "abort" event --
// whichever comes first. Before this fix, a stop landing inside a long
// inter-event gap had to wait out the rest of setTimeout(ms), because
// nothing here listened for the signal -- only the *next* iteration's
// top-of-loop `aborted(stop)` check in `go` (below) would notice it, up to
// the length of the longest recorded gap (~20s on some fixtures).
let sleep = (ms: int, ~stop: Fetch.AbortSignal.t): promise<unit> =>
  Promise.make((resolve, _reject) => {
    let timerRef = ref(None)
    let onAbort = () => {
      switch timerRef.contents {
      | Some(timer) => Node.Timer.clearTimeout(timer)
      | None => ()
      }
      resolve()
    }
    let timer = Node.Timer.setTimeoutHandle(() => {
      Fetch.AbortSignal.removeEventListener(stop, "abort", onAbort)
      resolve()
    }, ms)
    timerRef := Some(timer)
    Fetch.AbortSignal.addEventListener(stop, "abort", onAbort)
  })

// A non-positive speed would divide by zero or run the replay backward --
// ignore it and use realtime instead. Config.res's fromEnv already applies
// the same "ignore 0 or less" rule to STREAM_FIXTURE_SPEED, but play() is a
// standalone function a test can call with a hand-built speed, so it holds
// the rule too rather than trusting every caller to have applied it.
let safeSpeed = (speed: float): float => speed > 0.0 ? speed : 1.0

// Delivers each event to onEvent at ms / speed, timed from the moment
// play() is called -- an absolute schedule, not a running sum of
// inter-event gaps, so a slow tick (a GC pause, a busy event loop) is made
// up on the next wait instead of compounding into drift. Stops scheduling
// further deliveries once `stop` aborts.
let play = (
  events: array<recorded>,
  ~speed: float,
  ~stop: Fetch.AbortSignal.t,
  ~onEvent: Sse.event => unit,
): promise<unit> => {
  let effectiveSpeed = safeSpeed(speed)
  let startMs = Date.now()
  let rec go = (i: int): promise<unit> =>
    if Fetch.AbortSignal.aborted(stop) {
      Promise.resolve()
    } else if i >= Array.length(events) {
      Promise.resolve()
    } else {
      let r = Array.getUnsafe(events, i)
      let waitMs = r.ms /. effectiveSpeed -. (Date.now() -. startMs)
      let delayMs = waitMs > 0.0 ? Float.toInt(Math.round(waitMs)) : 0
      sleep(delayMs, ~stop)->Promise.then(() => {
        // sleep() above can resolve early because `stop` fired mid-wait,
        // not only because ms elapsed -- in that case this event was still
        // pending when the stop arrived, so treat it the same as the
        // aborted(stop) check at the top of this function: not delivered.
        if Fetch.AbortSignal.aborted(stop) {
          Promise.resolve()
        } else {
          onEvent(r.evt)
          go(i + 1)
        }
      })
    }
  go(0)
}
