// The network half of the streaming scene call. POSTs to Claude with
// "stream": true, reads the SSE body incrementally, and folds it through
// Sse -> ClaudeEvents -> SceneStream. SceneStream.update stays pure; this
// module is the effect edge (CLAUDE.md's TEA rule) — the one place that
// owns a mutable "model so far" while the read loop is in flight.
//
// Package search (2026-09-25, ~/code/CLAUDE.md "Finding ReScript
// packages"): the package index and `npm search --parseable rescript
// stream` both turned up only @rescript/webapi 0.1.0-experimental. Its
// README (npm, checked 2026-09-25) has no TextDecoder binding, an
// unconfirmed `read()` return shape, and a Response type that doesn't
// match this repo's Fetch.response. So this file and src/bindings/
// TextDecoder.res, plus the Response-streaming and AbortController/
// AbortSignal.any additions to src/bindings/Fetch.res, are our own small
// typed bindings — step 5 of that section, not a new dependency.

type outcome =
  | Completed(SceneStream.model)
  | Stopped(SceneStream.model)
  | TimedOut(SceneStream.model, int)
  | HttpFailed(int, string)
  | NoApiKey
  // Any other exception runLive's try/catch below did not already name:
  // a "fetch failed" from a dead connection, or the connection dropping
  // mid-stream. Carries the model built up so far, same as TimedOut and
  // Stopped do, plus the exception's own message.
  | StreamError(SceneStream.model, string)

// Same three headers ClaudeClient.postToClaude sends. Never logged —
// CLAUDE.md hard rule 3, secrets come from the environment only and never
// reach a log.
let headersFor = (apiKey: string): dict<string> =>
  Dict.fromArray([
    ("content-type", "application/json"),
    ("x-api-key", apiKey),
    ("anthropic-version", "2023-06-01"),
  ])

// buildBody's result is always a JSON object — ClaudeClient.buildRequestBody
// always returns one. Decode to a dict, add "stream" on a copy, re-encode.
// Typed JSON throughout, no %raw: GuardTest.res checks this equals the
// plain body plus "stream": true, so the eBay guard covers this path too.
let addStreamFlag = (body: JSON.t): JSON.t =>
  switch JSON.Decode.object(body) {
  | None => body
  | Some(d) => {
      let d2 = Dict.fromArray(Dict.toArray(d))
      Dict.set(d2, "stream", JSON.Encode.bool(true))
      JSON.Encode.object(d2)
    }
  }

let sleep = (ms: int): promise<unit> =>
  Promise.make((resolve, _reject) => Node.Timer.setTimeout(() => resolve(), ms))

let fixtureDelayMs = (): int =>
  Config.getEnv("STREAM_FIXTURE_DELAY_MS")->Option.flatMap(s => Int.fromString(s))->Option.getOr(150)

// Runs one already-decoded ClaudeEvents.t through SceneStream.update,
// reporting each log line it produced. The mutable ref is the effect
// edge's one seam: update() itself stays a pure (model, msg) => (model,
// array<logEvent>) fold.
let applyEvent = (
  modelRef: ref<SceneStream.model>,
  elapsedMs: unit => float,
  onEvent: (float, SceneStream.logEvent) => unit,
  claudeEvt: ClaudeEvents.t,
): unit => {
  let (model2, logs) = SceneStream.update(modelRef.contents, SceneStream.Event(claudeEvt))
  modelRef := model2
  Array.forEach(logs, log => onEvent(elapsedMs(), log))
}

// Reports every raw SSE event through onRaw before decoding it, then feeds
// a successful decode into applyEvent. A decode failure is dropped, same
// tolerance SceneStreamTest's own fixture runner uses.
let feedSse = (
  modelRef: ref<SceneStream.model>,
  elapsedMs: unit => float,
  onRaw: (float, Sse.event) => unit,
  onEvent: (float, SceneStream.logEvent) => unit,
  sseEvents: array<Sse.event>,
): unit =>
  Array.forEach(sseEvents, sseEvt => {
    onRaw(elapsedMs(), sseEvt)
    switch ClaudeEvents.decode(sseEvt) {
    | Ok(claudeEvt) => applyEvent(modelRef, elapsedMs, onEvent, claudeEvt)
    | Error(_) => ()
    }
  })

// Fixture mode: replay tests/fixtures/claude-stream.sse one SSE event at a
// time, off the real network, at STREAM_FIXTURE_DELAY_MS per event
// (default 150). Checks `stop` before every event, so a caller testing
// early-abort (e.g. --stop-after-first-item) doesn't have to wait out the
// rest of the file once it fires.
let runFixture = (
  ~config: Config.t,
  ~stop: Fetch.AbortSignal.t,
  ~onEvent: (float, SceneStream.logEvent) => unit,
  ~onRaw: (float, Sse.event) => unit,
  ~onHeaders: float => unit,
  ~startMs: float,
): promise<outcome> => {
  let elapsedMs = () => Date.now() -. startMs
  let text = Node.Fs.readFileUtf8(Node.Path.join([config.fixturesDir, "claude-stream.sse"]), "utf8")
  let (_, sseEvents) = Sse.feed(Sse.empty, text)
  let modelRef = ref(SceneStream.init)
  onHeaders(elapsedMs())
  let delayMs = fixtureDelayMs()
  let rec go = (i: int): promise<outcome> =>
    if Fetch.AbortSignal.aborted(stop) {
      Promise.resolve(Stopped(modelRef.contents))
    } else if i >= Array.length(sseEvents) {
      Promise.resolve(Completed(modelRef.contents))
    } else {
      feedSse(modelRef, elapsedMs, onRaw, onEvent, [Array.getUnsafe(sseEvents, i)])
      sleep(delayMs)->Promise.then(() => go(i + 1))
    }
  go(0)
}

// The real call. AbortSignal.any([timeout, stop]) covers both ways a
// stream can end early — ClaudeClient.timeoutFor(config)'s own deadline
// gives a TimeoutError reason, and the caller's `stop` gives the plain
// AbortError reason a bare controller.abort() produces — so catching by
// exception name (JsExn.name, same trick ClaudeClient.call already uses
// for its own TimeoutError) tells the two apart without a second binding.
let runLive = async (
  ~config: Config.t,
  ~apiKey: string,
  ~buildBody: (~structuredOutput: bool) => JSON.t,
  ~stop: Fetch.AbortSignal.t,
  ~onEvent: (float, SceneStream.logEvent) => unit,
  ~onRaw: (float, Sse.event) => unit,
  ~onHeaders: float => unit,
  ~startMs: float,
): outcome => {
  let elapsedMs = () => Date.now() -. startMs
  let modelRef = ref(SceneStream.init)
  let readerRef: ref<option<Fetch.readableStreamReader>> = ref(None)

  let attempt = (structuredOutput: bool): promise<Fetch.response> => {
    let body = addStreamFlag(buildBody(~structuredOutput))
    let signal = Fetch.AbortSignal.any([
      Fetch.AbortSignal.timeout(ClaudeClient.timeoutFor(config)),
      stop,
    ])
    Fetch.fetch(
      config.claudeUrl->Option.getOr(ClaudeClient.messagesUrl),
      ~init={Fetch.method: "POST", headers: headersFor(apiKey), body: JSON.stringify(body), signal},
    )
  }

  // Same 400/output_config retry rule as ClaudeClient.send: one retry,
  // without output_config, only when structured output was on and the
  // error text names it.
  let resolveResponse = async (resp: Fetch.response): result<Fetch.response, (int, string)> =>
    if Fetch.ok(resp) {
      Ok(resp)
    } else if Fetch.status(resp) == 400 && config.structuredOutput {
      let errText = await Fetch.text(resp)
      if String.includes(errText, "output_config") {
        Console.log("claude: retrying without output_config after 400 (stream)")
        let resp2 = await attempt(false)
        if Fetch.ok(resp2) {
          Ok(resp2)
        } else {
          Error((Fetch.status(resp2), await Fetch.text(resp2)))
        }
      } else {
        Error((400, errText))
      }
    } else {
      Error((Fetch.status(resp), await Fetch.text(resp)))
    }

  let safeCancel = async () =>
    switch readerRef.contents {
    | None => ()
    | Some(reader) =>
        try {
          let _ = await Fetch.cancel(reader)
        } catch {
        | JsExn(_) => ()
        }
    }

  try {
    let resp1 = await attempt(config.structuredOutput)
    switch await resolveResponse(resp1) {
    | Error((status, text)) => HttpFailed(status, text)
    | Ok(resp) =>
        onHeaders(elapsedMs())
        switch Fetch.body(resp) {
        | None => HttpFailed(Fetch.status(resp), "response had no body to stream")
        | Some(stream) =>
            let reader = Fetch.getReader(stream)
            readerRef := Some(reader)
            let decoder = TextDecoder.make()
            let sseStateRef = ref(Sse.empty)
            let rec readLoop = async (): outcome => {
              let chunk = await Fetch.read(reader)
              if chunk.done {
                let flushed = TextDecoder.flush(decoder)
                if flushed != "" {
                  let (sseState2, sseEvents) = Sse.feed(sseStateRef.contents, flushed)
                  sseStateRef := sseState2
                  feedSse(modelRef, elapsedMs, onRaw, onEvent, sseEvents)
                }
                Completed(modelRef.contents)
              } else {
                switch chunk.value {
                | None => await readLoop()
                | Some(bytes) =>
                    let text = TextDecoder.decodeStream(decoder, bytes, {stream: true})
                    let (sseState2, sseEvents) = Sse.feed(sseStateRef.contents, text)
                    sseStateRef := sseState2
                    feedSse(modelRef, elapsedMs, onRaw, onEvent, sseEvents)
                    await readLoop()
                }
              }
            }
            await readLoop()
        }
    }
  } catch {
  | JsExn(e) if JsExn.name(e) == Some("TimeoutError") =>
      await safeCancel()
      TimedOut(modelRef.contents, ClaudeClient.timeoutFor(config))
  | JsExn(e) if JsExn.name(e) == Some("AbortError") =>
      await safeCancel()
      Stopped(modelRef.contents)
  // Anything else: a "fetch failed" from a dead connection, or the
  // connection dropping mid-read (chunk.done never true, no clean end).
  // This used to fall through uncaught and reject runLive's promise —
  // after the caller (StreamRoute.handle) had already sent its 200 SSE
  // headers, so the rejection reached Server.res's server-level handler
  // too late to answer anything but a crash (ERR_HTTP_HEADERS_SENT).
  | JsExn(e) =>
      await safeCancel()
      StreamError(modelRef.contents, JsExn.message(e)->Option.getOr("stream failed"))
  }
}

let run = async (
  ~config: Config.t,
  ~buildBody: (~structuredOutput: bool) => JSON.t,
  ~stop: Fetch.AbortSignal.t,
  ~onEvent: (float, SceneStream.logEvent) => unit,
  ~onRaw: (float, Sse.event) => unit,
  ~onHeaders: float => unit,
): outcome => {
  let startMs = Date.now()
  if config.fixtures {
    await runFixture(~config, ~stop, ~onEvent, ~onRaw, ~onHeaders, ~startMs)
  } else {
    switch config.anthropicApiKey {
    | None => NoApiKey
    | Some(apiKey) =>
        await runLive(~config, ~apiKey, ~buildBody, ~stop, ~onEvent, ~onRaw, ~onHeaders, ~startMs)
    }
  }
}
