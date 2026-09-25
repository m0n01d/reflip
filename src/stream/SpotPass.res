// The spot pass: a second, toolless Claude call that runs next to the
// priced pass and returns only item names and boxes (docs/scan-ui.md §1
// decision 1). It has its own tiny TEA core, separate from SceneStream's,
// because a spot item has none of the fields (query, estimateLowUsd,
// basis, confidence, sources...) SceneStream.ItemDecode.claudeItem
// requires — feeding spot JSON through that decoder would reject every
// item.
//
// This module reuses ClaudeStream.res's already-generic helpers
// (headersFor, addStreamFlag, sleep, fixtureDelayMs — none of which
// mention SceneStream) rather than its run/runLive/runFixture, which are
// hard-wired to SceneStream.model. Branch claude/stall-fix changes
// ClaudeStream.res later, so this file makes zero edits there: the
// network loop below is its own short copy of the same fetch -> Sse ->
// ClaudeEvents shape, folded into this file's own model instead.

module D = JsonCombinators.Json.Decode

type logEvent =
  | Started({inputTokens: int})
  | ItemFound({index: int, name: string, box: array<int>})
  | Finished({usage: Types.usage})
  | Failed(string)

type model = {
  scanner: ItemScanner.t,
  usage: Types.usage,
}

let emptyUsage: Types.usage = {
  Types.inputTokens: 0,
  outputTokens: 0,
  cacheReadInputTokens: 0,
  cacheCreationInputTokens: 0,
  webSearchRequests: 0,
}

let init: model = {scanner: ItemScanner.empty, usage: emptyUsage}

module ItemDecode = {
  let spotItem: D.t<(string, array<int>)> = D.object(field => (
    field.required("name", D.string),
    field.required("box", D.array(D.int)),
  ))
}

let applyFound = (model: model, found: ItemScanner.found): (model, array<logEvent>) =>
  switch found {
  | ItemScanner.ItemClosed({index, json}) =>
    switch JsonCombinators.Json.decode(json, ItemDecode.spotItem) {
    | Ok((name, box)) => (model, [ItemFound({index, name, box})])
    | Error(_) => (model, [])
    }
  | ItemScanner.BoxClosed(_) => (model, [])
  | ItemScanner.ItemUnparsable(_) => (model, [])
  }

let applyFoundAll = (model: model, found: array<ItemScanner.found>): (model, array<logEvent>) =>
  Array.reduce(found, (model, []), ((m, acc), f) => {
    let (m2, evts) = applyFound(m, f)
    (m2, Array.concat(acc, evts))
  })

// Pure fold: one decoded ClaudeEvents.t in, the model it produces and the
// log lines it fired, out. No block-index or open-block tracking, unlike
// SceneStream — the spot pass has no tools and no thinking-vs-text
// ambiguity to resolve, so every text delta belongs to the one JSON reply.
let update = (model: model, evt: ClaudeEvents.t): (model, array<logEvent>) =>
  switch evt {
  | ClaudeEvents.MessageStart({usage}) => (
      {...model, usage},
      [Started({inputTokens: usage.inputTokens})],
    )
  | ClaudeEvents.BlockDelta({delta: ClaudeEvents.TextDelta(text)}) =>
    let (scanner2, found) = ItemScanner.feed(model.scanner, text)
    applyFoundAll({...model, scanner: scanner2}, found)
  | ClaudeEvents.MessageDelta({usage}) => ({...model, usage}, [])
  | ClaudeEvents.MessageStop => (model, [Finished({usage: model.usage})])
  | ClaudeEvents.ApiError({errorType, message}) => (model, [Failed(errorType ++ ": " ++ message)])
  | ClaudeEvents.BlockStart(_)
  | ClaudeEvents.BlockDelta(_)
  | ClaudeEvents.BlockStop(_)
  | ClaudeEvents.Ping
  | ClaudeEvents.Unknown(_) => (model, [])
  }

// The photo and system prompt for the spot pass: same model and same
// image bytes as the priced call, no "tools" key at all (docs/scan-ui.md
// §1 decision 1: "no tools"), and structured output shaped as
// {items: [{name, box}]} (SystemPrompt.spotOutputFormat).
let buildRequestBody = (
  ~model: string,
  ~imageBase64: string,
  ~structuredOutput: bool,
  ~width: int,
  ~height: int,
): JSON.t => {
  let imageBlock = Json.obj([
    ("type", Json.str("image")),
    (
      "source",
      Json.obj([
        ("type", Json.str("base64")),
        ("media_type", Json.str("image/jpeg")),
        ("data", Json.str(imageBase64)),
      ]),
    ),
  ])
  let text =
    "This photo is " ++
    Int.toString(width) ++
    " pixels wide and " ++
    Int.toString(height) ++ " pixels tall. Name and box each resellable item on this table."
  let textBlock = Json.obj([("type", Json.str("text")), ("text", Json.str(text))])
  let base = [
    ("model", Json.str(model)),
    ("max_tokens", Json.num(Int.toFloat(ClaudeClient.maxTokens))),
    ("system", Json.str(SystemPrompt.spotPrompt)),
    (
      "messages",
      Json.arr([
        Json.obj([("role", Json.str("user")), ("content", Json.arr([imageBlock, textBlock]))]),
      ]),
    ),
  ]
  let fields =
    structuredOutput
      ? Array.concat(base, [("output_config", Json.obj([("format", SystemPrompt.spotOutputFormat)]))])
      : base
  Json.obj(fields)
}

type outcome =
  | Completed(model)
  | Stopped(model)
  | TimedOut(model, int)
  | HttpFailed(int, string)
  | NoApiKey
  // Fixture mode, no tests/fixtures/claude-spot(.events.jsonl[.gz]|.sse)
  // found. Distinct from ClaudeStream's outcomes: the priced pass has no
  // analogous "missing fixture" case, because claude-stream.sse always
  // ships in the repo.
  | NoFixture(string)
  // Any other exception runLive's try/catch did not already name, same as
  // ClaudeStream.StreamError: the model so far, plus the message.
  | StreamError(model, string)

let applyEvent = (
  modelRef: ref<model>,
  elapsedMs: unit => float,
  onEvent: (float, logEvent) => unit,
  claudeEvt: ClaudeEvents.t,
): unit => {
  let (model2, logs) = update(modelRef.contents, claudeEvt)
  modelRef := model2
  Array.forEach(logs, log => onEvent(elapsedMs(), log))
}

let feedSse = (
  modelRef: ref<model>,
  elapsedMs: unit => float,
  onRaw: (float, Sse.event) => unit,
  onEvent: (float, logEvent) => unit,
  sseEvents: array<Sse.event>,
): unit =>
  Array.forEach(sseEvents, sseEvt => {
    onRaw(elapsedMs(), sseEvt)
    switch ClaudeEvents.decode(sseEvt) {
    | Ok(claudeEvt) => applyEvent(modelRef, elapsedMs, onEvent, claudeEvt)
    | Error(_) => ()
    }
  })

// Fixture mode: FixtureReplay.findFile/readEvents/play are already fully
// generic (Sse.event in, no SceneStream coupling), so this reuses them
// unchanged with base name "claude-spot". Falls back to a plain
// claude-spot.sse the way ClaudeStream.runFixture falls back to
// claude-stream.sse, and to NoFixture when neither exists — StreamRoute
// turns that into a spot-failed event (docs/scan-ui.md wave 2 brief,
// item 3).
let runFixture = (
  ~config: Config.t,
  ~stop: Fetch.AbortSignal.t,
  ~onEvent: (float, logEvent) => unit,
  ~onRaw: (float, Sse.event) => unit,
  ~startMs: float,
): promise<outcome> => {
  let elapsedMs = () => Date.now() -. startMs
  let modelRef = ref(init)
  switch FixtureReplay.findFile(config.fixturesDir, "claude-spot") {
  | Some(path) =>
    let events = FixtureReplay.readEvents(path)
    let speed = config.streamFixtureSpeed->Option.getOr(1.0)
    FixtureReplay.play(events, ~speed, ~stop, ~onEvent=sseEvt =>
      feedSse(modelRef, elapsedMs, onRaw, onEvent, [sseEvt])
    )->Promise.then(() =>
      Promise.resolve(
        Fetch.AbortSignal.aborted(stop) ? Stopped(modelRef.contents) : Completed(modelRef.contents),
      )
    )
  | None =>
    let plainPath = Node.Path.join([config.fixturesDir, "claude-spot.sse"])
    if Node.Fs.existsSync(plainPath) {
      let text = Node.Fs.readFileUtf8(plainPath, "utf8")
      let (_, sseEvents) = Sse.feed(Sse.empty, text)
      let delayMs = ClaudeStream.fixtureDelayMs()
      let rec go = (i: int): promise<outcome> =>
        if Fetch.AbortSignal.aborted(stop) {
          Promise.resolve(Stopped(modelRef.contents))
        } else if i >= Array.length(sseEvents) {
          Promise.resolve(Completed(modelRef.contents))
        } else {
          feedSse(modelRef, elapsedMs, onRaw, onEvent, [Array.getUnsafe(sseEvents, i)])
          ClaudeStream.sleep(delayMs)->Promise.then(() => go(i + 1))
        }
      go(0)
    } else {
      Promise.resolve(NoFixture("no claude-spot fixture found in " ++ config.fixturesDir))
    }
  }
}

// The real call. Same AbortSignal.any([timeout, stop]) composition as
// ClaudeStream.runLive, and the same one-retry-without-output_config
// rule on a 400 that names it.
let runLive = async (
  ~config: Config.t,
  ~apiKey: string,
  ~buildBody: (~structuredOutput: bool) => JSON.t,
  ~stop: Fetch.AbortSignal.t,
  ~onEvent: (float, logEvent) => unit,
  ~onRaw: (float, Sse.event) => unit,
  ~startMs: float,
): outcome => {
  let elapsedMs = () => Date.now() -. startMs
  let modelRef = ref(init)
  let readerRef: ref<option<Fetch.readableStreamReader>> = ref(None)

  let attempt = (structuredOutput: bool): promise<Fetch.response> => {
    let body = ClaudeStream.addStreamFlag(buildBody(~structuredOutput))
    let signal = Fetch.AbortSignal.any([
      Fetch.AbortSignal.timeout(ClaudeClient.timeoutFor(config)),
      stop,
    ])
    Fetch.fetch(
      config.claudeUrl->Option.getOr(ClaudeClient.messagesUrl),
      ~init={
        Fetch.method: "POST",
        headers: ClaudeStream.headersFor(apiKey),
        body: JSON.stringify(body),
        signal,
      },
    )
  }

  let resolveResponse = async (resp: Fetch.response): result<Fetch.response, (int, string)> =>
    if Fetch.ok(resp) {
      Ok(resp)
    } else if Fetch.status(resp) == 400 && config.structuredOutput {
      let errText = await Fetch.text(resp)
      if String.includes(errText, "output_config") {
        Console.log("claude: retrying spot pass without output_config after 400 (stream)")
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
  // connection dropping mid-read. Same catch-all as ClaudeStream.runLive:
  // a rejection here would go unhandled while StreamRoute.handle still
  // awaits the priced pass, and crash the process.
  | JsExn(e) =>
    await safeCancel()
    StreamError(modelRef.contents, JsExn.message(e)->Option.getOr("spot stream failed"))
  }
}

let run = async (
  ~config: Config.t,
  ~buildBody: (~structuredOutput: bool) => JSON.t,
  ~stop: Fetch.AbortSignal.t,
  ~onEvent: (float, logEvent) => unit,
  ~onRaw: (float, Sse.event) => unit,
): outcome => {
  let startMs = Date.now()
  if config.fixtures {
    await runFixture(~config, ~stop, ~onEvent, ~onRaw, ~startMs)
  } else {
    switch config.anthropicApiKey {
    | None => NoApiKey
    | Some(apiKey) => await runLive(~config, ~apiKey, ~buildBody, ~stop, ~onEvent, ~onRaw, ~startMs)
    }
  }
}
