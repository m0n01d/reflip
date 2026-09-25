// Handler for POST /api/scene/stream. EventSource cannot POST a photo, so
// the page POSTs with fetch and reads response.body as a stream; this is
// the server side of that: an SSE (text/event-stream) reply the page reads
// incrementally, one event per thing Claude just did.
//
// Deliberately does not depend on Server.res, so Server.res can depend on
// this module without a cycle. The pieces it would otherwise need from
// Server (the eBay merge, the scene-reply building) arrive as the
// `buildSceneReply` parameter instead — Server.res's own buildSceneReply,
// passed in by route.

let jsonError = (res: Node.HttpServer.response, status: int, message: string): unit => {
  Node.HttpServer.writeHead(res, status, Dict.fromArray([("Content-Type", "application/json")]))
  Node.HttpServer.endWithBody(res, JSON.stringify(Json.obj([("error", Json.str(message))])))
}

// Types.replyItem shape for an item that has not been through the eBay
// merge yet (mid-stream: only Claude's own fields are known). ebay and box
// are filled in later, once buildSceneReply runs after Claude finishes —
// same reasoning SceneStream.takeBoxFor documents for why the box the
// scanner found isn't attached here either.
let toReplyItemPartial = (item: Types.claudeItem): Types.replyItem => {
  Types.name: item.name,
  query: item.query,
  confidence: item.confidence,
  estimateLowUsd: item.estimateLowUsd,
  estimateHighUsd: item.estimateHighUsd,
  basis: item.basis,
  sources: item.sources,
  ebay: None,
  soldSearchUrl: EbayClient.soldSearchUrl(item.query),
  box: None,
}

// data/raw/<sceneId>.events.jsonl: one line per raw SSE event Claude sent,
// each tagged with its ms since the photo arrived. The streaming route's
// analog of SceneLog.writeRaw — there is no single raw JSON blob to write,
// since the reply arrived as a stream, so this is its own small file
// instead, and its path becomes the reply's outputPath.
let writeRawEvents = (dataDir: string, sceneId: string, events: array<(float, Sse.event)>): string => {
  SceneLog.ensureDirs(dataDir)
  let path = Node.Path.join([dataDir, "raw", sceneId ++ ".events.jsonl"])
  let lines = Array.map(events, ((ms, e)) =>
    JSON.stringify(
      Json.obj([("t", Json.num(ms)), ("event", Json.str(e.event)), ("data", Json.str(e.data))]),
    )
  )
  Node.Fs.writeFileSync(path, Array.length(lines) == 0 ? "" : Array.join(lines, "\n") ++ "\n")
  path
}

let handle = async (
  ~config: Config.t,
  ~model: string,
  ~body: Node.Buffer.t,
  ~res: Node.HttpServer.response,
  ~buildSceneReply: (
    ~config: Config.t,
    ~model: string,
    ~sentWidth: int,
    ~sentHeight: int,
    ~serverStart: float,
    ~claudeMs: float,
    ~sceneId: string,
    ~outputPath: string,
    ~items: array<Types.claudeItem>,
    ~usage: Types.usage,
  ) => promise<Types.sceneReply>,
): unit =>
  switch JpegSize.dimensions(body) {
  | None => jsonError(res, 400, "could not read the photo's width and height")
  | Some((sentWidth, sentHeight)) => {
      let startMs = Date.now()
      let elapsedMs = () => Date.now() -. startMs
      let sceneId = Node.Crypto.randomUUID()
      let imageBase64 = Node.Buffer.toStringWithEncoding(body, "base64")

      Node.HttpServer.writeHead(
        res,
        200,
        Dict.fromArray([
          ("Content-Type", "text/event-stream; charset=utf-8"),
          ("Cache-Control", "no-cache, no-transform"),
          ("X-Accel-Buffering", "no"),
        ]),
      )
      Node.HttpServer.flushHeaders(res)
      // See Node.res's onResponseError doc comment: an unlistened "error" on
      // a response is an uncaught exception, and a write that loses the
      // race with a client abort (below) can raise one.
      Node.HttpServer.onResponseError(res, "error", () => ())

      let writeEvent = (event: string, data: JSON.t): unit =>
        if !Node.HttpServer.writableEnded(res) {
          Node.HttpServer.write(res, Sse.encode(~event, ~data))
        }

      writeEvent(
        "photo-received",
        Json.obj([
          ("bytes", Json.num(Int.toFloat(Node.Buffer.length(body)))),
          ("width", Json.num(Int.toFloat(sentWidth))),
          ("height", Json.num(Int.toFloat(sentHeight))),
        ]),
      )

      // Self-terminating: each beat reschedules itself only once it has
      // confirmed the response is still open, so this needs no clearTimeout
      // (Node.res has none — see its Timer module doc comment) and just
      // stops once `end` has been called below.
      let rec heartbeat = () =>
        Node.Timer.setTimeout(() =>
          if !Node.HttpServer.writableEnded(res) {
            Node.HttpServer.write(res, Sse.comment("heartbeat"))
            heartbeat()
          }
        , 10_000)
      heartbeat()

      // The one AbortSignal ClaudeStream.run takes as `stop`. Aborted from
      // the response's "close" handler below when that fires before we
      // ourselves ever called "end" — i.e. the client hung up first.
      let controller = Fetch.AbortController.make()
      Node.HttpServer.onClose(res, "close", () =>
        if !Node.HttpServer.writableEnded(res) {
          Fetch.AbortController.abort(controller)
        }
      )

      // Set once ClaudeStream's onEvent callback sees Finished, so the
      // Completed branch below can hand buildSceneReply the same "how long
      // did Claude take" figure the `done` event already reported.
      let claudeMsRef = ref(0.0)
      let rawEvents: array<(float, Sse.event)> = []

      let onEvent = (ms: float, evt: SceneStream.logEvent): unit =>
        switch evt {
        | SceneStream.ClaudeStarted({inputTokens}) =>
          writeEvent(
            "claude-started",
            Json.obj([("t", Json.num(ms)), ("inputTokens", Json.num(Int.toFloat(inputTokens)))]),
          )
        | SceneStream.Thinking => writeEvent("thinking", Json.obj([("t", Json.num(ms))]))
        | SceneStream.ToolRunStarted({id, name}) =>
          writeEvent(
            "tool-run",
            Json.obj([("t", Json.num(ms)), ("id", Json.str(id)), ("name", Json.str(name))]),
          )
        | SceneStream.ToolRunDone({id, name, status}) =>
          writeEvent(
            "tool-done",
            Json.obj([
              ("t", Json.num(ms)),
              ("id", Json.str(id)),
              ("name", Json.str(name)),
              ("status", Types.encodeOptString(status)),
            ]),
          )
        | SceneStream.SearchStarted({id, query}) =>
          writeEvent(
            "search-started",
            Json.obj([
              ("t", Json.num(ms)),
              ("id", Json.str(id)),
              ("query", Types.encodeOptString(query)),
            ]),
          )
        | SceneStream.SearchDone({id, resultCount}) =>
          writeEvent(
            "search-done",
            Json.obj([
              ("t", Json.num(ms)),
              ("id", Json.str(id)),
              ("count", Json.num(Int.toFloat(resultCount))),
            ]),
          )
        | SceneStream.SearchFailed({id, errorCode}) =>
          writeEvent(
            "search-failed",
            Json.obj([("t", Json.num(ms)), ("id", Json.str(id)), ("errorCode", Json.str(errorCode))]),
          )
        | SceneStream.BoxFound({index, box}) =>
          writeEvent(
            "box",
            Json.obj([
              ("t", Json.num(ms)),
              ("index", Json.num(Int.toFloat(index))),
              ("box", Json.arr(Array.map(box, n => Json.num(Int.toFloat(n))))),
            ]),
          )
        | SceneStream.ItemFound({index, item}) =>
          writeEvent(
            "item",
            Json.obj([
              ("t", Json.num(ms)),
              ("index", Json.num(Int.toFloat(index))),
              ("item", Types.encodeReplyItem(toReplyItemPartial(item))),
            ]),
          )
        // Not in the brief's event list — closest fit is the same `error`
        // shape the outer outcomes below use, rather than dropping a
        // failure silently.
        | SceneStream.ItemRejected({index, reason}) =>
          writeEvent(
            "error",
            Json.obj([
              ("t", Json.num(ms)),
              ("message", Json.str("item " ++ Int.toString(index) ++ " rejected: " ++ reason)),
            ]),
          )
        | SceneStream.Finished({usage}) => {
            claudeMsRef := ms
            writeEvent(
              "done",
              Json.obj([
                ("claudeMs", Json.num(ms)),
                ("inputTokens", Json.num(Int.toFloat(usage.inputTokens))),
                ("outputTokens", Json.num(Int.toFloat(usage.outputTokens))),
                ("webSearches", Json.num(Int.toFloat(usage.webSearchRequests))),
                ("usd", Json.num(Pricing.usdCost(~model, ~usage))),
              ]),
            )
          }
        | SceneStream.StreamFailed(msg) =>
          writeEvent("error", Json.obj([("t", Json.num(ms)), ("message", Json.str(msg))]))
        }

      let outcome = await ClaudeStream.run(
        ~config,
        ~buildBody=(~structuredOutput) =>
          ClaudeClient.buildRequestBody(
            ~model,
            ~imageBase64,
            ~structuredOutput,
            ~mode=ClaudeClient.Scene({width: sentWidth, height: sentHeight}),
          ),
        ~stop=Fetch.AbortController.signal(controller),
        ~onEvent,
        ~onRaw=(ms, sseEvt) => Array.push(rawEvents, (ms, sseEvt))->ignore,
        ~onHeaders=_ms => (),
      )

      switch outcome {
      | ClaudeStream.Completed(m) => {
          let outputPath = writeRawEvents(config.dataDir, sceneId, rawEvents)
          let reply = await buildSceneReply(
            ~config,
            ~model,
            ~sentWidth,
            ~sentHeight,
            ~serverStart=startMs,
            ~claudeMs=claudeMsRef.contents,
            ~sceneId,
            ~outputPath,
            ~items=SceneStream.items(m),
            ~usage=SceneStream.usage(m),
          )
          SceneLog.appendLine(config.dataDir, Types.encodeSceneReply(reply))
          writeEvent("scene", Types.encodeSceneReply(reply))
          if !Node.HttpServer.writableEnded(res) {
            Node.HttpServer.endWithBody(res, "")
          }
        }
      | ClaudeStream.Stopped(m) => {
          let ms = elapsedMs()
          let items = SceneStream.items(m)
          writeEvent("stop", Json.obj([("t", Json.num(ms))]))
          SceneLog.appendLine(
            config.dataDir,
            Json.obj([
              ("stopped", Json.boolJ(true)),
              ("sceneId", Json.str(sceneId)),
              ("model", Json.str(model)),
              ("t", Json.num(ms)),
              (
                "items",
                Json.arr(Array.map(items, item => Types.encodeReplyItem(toReplyItemPartial(item)))),
              ),
            ]),
          )
          if !Node.HttpServer.writableEnded(res) {
            Node.HttpServer.endWithBody(res, "")
          }
        }
      | ClaudeStream.TimedOut(_, timeoutMs) => {
          let msg =
            "Claude took longer than " ++ Float.toString(Int.toFloat(timeoutMs) /. 1000.0) ++ " s"
          writeEvent("error", Json.obj([("message", Json.str(msg))]))
          if !Node.HttpServer.writableEnded(res) {
            Node.HttpServer.endWithBody(res, "")
          }
        }
      | ClaudeStream.HttpFailed(status, text) => {
          let msg = "Claude request failed (" ++ Int.toString(status) ++ "): " ++ text
          writeEvent("error", Json.obj([("message", Json.str(msg))]))
          if !Node.HttpServer.writableEnded(res) {
            Node.HttpServer.endWithBody(res, "")
          }
        }
      | ClaudeStream.NoApiKey => {
          writeEvent(
            "error",
            Json.obj([("message", Json.str("no ANTHROPIC_API_KEY set and FIXTURES is not 1"))]),
          )
          if !Node.HttpServer.writableEnded(res) {
            Node.HttpServer.endWithBody(res, "")
          }
        }
      }
    }
  }
