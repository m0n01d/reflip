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
  size: item.size,
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
    ~quarterSeen: bool,
  ) => promise<Types.sceneReply>,
): unit =>
  switch JpegSize.dimensions(body) {
  | None => jsonError(res, 400, "could not read the photo's width and height")
  | Some((sentWidth, sentHeight)) => {
      let startMs = Date.now()
      let elapsedMs = () => Date.now() -. startMs
      let sceneId = Node.Crypto.randomUUID()
      let imageBase64 = Node.Buffer.toStringWithEncoding(body, "base64")

      // The one AbortSignal ClaudeStream.run takes as `stop`. Only a stop
      // request (SceneRegistry.requestStop, via POST /api/scene/:id/stop)
      // or the time limit aborts it now — a dropped connection alone must
      // not (docs/scan-ui.md §1 decision 3).
      let controller = Fetch.AbortController.make()
      // Registers `res` as the scene's first listener and writes the SSE
      // headers. Every event from here on goes out through
      // SceneRegistry.push, so a GET /api/scene/:id/events reconnect sees
      // exactly what this connection would have. If the client closes,
      // SceneRegistry's own onClose handler only detaches `res` — it never
      // touches `controller`.
      SceneRegistry.create(sceneId, controller, res)

      // Fixture-mode test switch only: destroys the raw socket under `res`
      // partway through the scene, to simulate an abrupt client drop
      // without going through a real network failure. The scene keeps
      // running either way — this exists to prove that.
      if config.fixtures {
        switch Config.getEnv("STREAM_DROP_AFTER_MS")->Option.flatMap(s => Int.fromString(s)) {
        | Some(dropMs) =>
          Node.Timer.setTimeout(
            () => Node.HttpServer.destroySocket(Node.HttpServer.socket(res)),
            dropMs,
          )
        | None => ()
        }
      }

      let write = (evt: ScanEvent.t): unit => SceneRegistry.push(sceneId, evt)

      write(
        ScanEvent.PhotoReceived({
          sceneId,
          bytes: Node.Buffer.length(body),
          width: sentWidth,
          height: sentHeight,
        }),
      )

      // Set once ClaudeStream's onEvent callback sees Finished, so the
      // Completed branch below can hand buildSceneReply the same "how long
      // did Claude take" figure the `done` event already reported.
      let claudeMsRef = ref(0.0)
      let rawEvents: array<(float, Sse.event)> = []
      // Set in the Finished branch below when Claude stops on max_tokens.
      // Checked once the HTTP stream itself closes (Completed), because
      // MessageStop can arrive before the underlying response finishes.
      let cutOffRef: ref<option<Types.usage>> = ref(None)

      let onEvent = (ms: float, evt: SceneStream.logEvent): unit =>
        switch evt {
        | SceneStream.ClaudeStarted({inputTokens}) =>
          write(ScanEvent.ClaudeStarted({t: ms, inputTokens}))
        | SceneStream.Thinking => write(ScanEvent.Thinking({t: ms}))
        | SceneStream.ToolRunStarted({id, name}) => write(ScanEvent.ToolRun({t: ms, id, name}))
        | SceneStream.ToolRunDone({id, name, status}) =>
          write(ScanEvent.ToolDone({t: ms, id, name, status}))
        | SceneStream.SearchStarted({id, query}) =>
          write(ScanEvent.SearchStarted({t: ms, id, query}))
        | SceneStream.SearchDone({id, resultCount}) =>
          write(ScanEvent.SearchDone({t: ms, id, count: resultCount}))
        | SceneStream.SearchFailed({id, errorCode}) =>
          write(ScanEvent.SearchFailed({t: ms, id, errorCode}))
        | SceneStream.BoxFound({index, box}) => write(ScanEvent.Box({t: ms, index, box}))
        | SceneStream.ItemFound({index, item}) =>
          write(ScanEvent.Item({t: ms, index, item: toReplyItemPartial(item)}))
        // Not in the brief's event list — closest fit is the same `error`
        // shape the outer outcomes below use, rather than dropping a
        // failure silently.
        | SceneStream.ItemRejected({index, reason}) =>
          write(
            ScanEvent.ErrorEvent({
              t: ms,
              message: "item " ++ Int.toString(index) ++ " rejected: " ++ reason,
            }),
          )
        | SceneStream.Finished({stopReason, usage}) => {
            claudeMsRef := ms
            if stopReason == "max_tokens" {
              cutOffRef := Some(usage)
            } else {
              write(
                ScanEvent.Done({
                  claudeMs: ms,
                  inputTokens: usage.inputTokens,
                  outputTokens: usage.outputTokens,
                  webSearches: usage.webSearchRequests,
                  usd: Pricing.usdCost(~model, ~usage),
                }),
              )
            }
          }
        | SceneStream.StreamFailed(msg) => write(ScanEvent.ErrorEvent({t: ms, message: msg}))
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
      | ClaudeStream.Completed(m) =>
        switch cutOffRef.contents {
        // Same rule as ClaudeClient.parseClaudeJson's CutOff case and
        // Server.res's handleScene: a max_tokens stop is not a normal
        // finish. No eBay merge, no `scene` event — log the cut-off scene
        // (same fields as Server.res's CutOff branch, adapted to the
        // stream's own raw-events dump) and end the request as failed.
        | Some(usage) => {
            let ms = elapsedMs()
            let outputPath = writeRawEvents(config.dataDir, sceneId, rawEvents)
            let cost: Types.cost = {
              Types.usd: Pricing.usdCost(~model, ~usage),
              inputTokens: usage.inputTokens,
              outputTokens: usage.outputTokens,
              cacheReadTokens: usage.cacheReadInputTokens,
              cacheWriteTokens: usage.cacheCreationInputTokens,
              webSearches: usage.webSearchRequests,
            }
            SceneLog.appendLine(
              config.dataDir,
              Json.obj([
                ("sceneId", Json.str(sceneId)),
                ("model", Json.str(model)),
                ("error", Json.str("reply cut off")),
                ("stopReason", Json.str("max_tokens")),
                ("outputPath", Json.str(outputPath)),
                ("imageWidth", Json.num(Int.toFloat(sentWidth))),
                ("imageHeight", Json.num(Int.toFloat(sentHeight))),
                ("timing", Json.obj([("claudeMs", Json.num(claudeMsRef.contents))])),
                ("cost", Types.encodeCost(cost)),
              ]),
            )
            Console.error(
              "reflip: scene " ++
              sceneId ++
              " cut off (stream), " ++
              Int.toString(usage.outputTokens) ++
              " output tokens, " ++
              Int.toString(usage.webSearchRequests) ++
              " web searches, $" ++
              Float.toString(cost.usd),
            )
            write(ScanEvent.ErrorEvent({t: ms, message: "reply cut off"}))
            write(ScanEvent.End({t: ms, status: ScanEvent.EndStatus.Failed}))
          }
        | None => {
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
              ~quarterSeen=SceneStream.quarterSeen(m),
            )
            SceneLog.appendLine(config.dataDir, Types.encodeSceneReply(reply))
            write(ScanEvent.Scene(reply))
            write(ScanEvent.End({t: elapsedMs(), status: ScanEvent.EndStatus.Done}))
          }
        }
      | ClaudeStream.Stopped(m) => {
          let ms = elapsedMs()
          let items = SceneStream.items(m)
          write(ScanEvent.Stop({t: ms}))
          // Kept exactly as before (docs/scan-ui.md wave brief: "keep the
          // usd null logging of stopped ... scenes") — no cost field, since
          // the usage seen so far is not a real bill. The eBay-merged
          // `scene` event below is for the live client only; it is not
          // logged a second time here with that partial-usage cost.
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
          let outputPath = writeRawEvents(config.dataDir, sceneId, rawEvents)
          let reply = await buildSceneReply(
            ~config,
            ~model,
            ~sentWidth,
            ~sentHeight,
            ~serverStart=startMs,
            ~claudeMs=ms,
            ~sceneId,
            ~outputPath,
            ~items,
            ~usage=SceneStream.usage(m),
            ~quarterSeen=SceneStream.quarterSeen(m),
          )
          write(ScanEvent.Scene(reply))
          write(ScanEvent.End({t: elapsedMs(), status: ScanEvent.EndStatus.Stopped}))
        }
      | ClaudeStream.TimedOut(m, timeoutMs) => {
          let ms = elapsedMs()
          let msg =
            "Claude took longer than " ++ Float.toString(Int.toFloat(timeoutMs) /. 1000.0) ++ " s"
          write(ScanEvent.ErrorEvent({t: ms, message: msg}))
          // Same "usd null" shape as the Stopped branch above, and for the
          // same reason: kept as its own line even though the `scene`
          // event below now also merges eBay for the items found so far.
          SceneLog.appendLine(
            config.dataDir,
            Json.obj([
              ("timedOut", Json.boolJ(true)),
              ("sceneId", Json.str(sceneId)),
              ("model", Json.str(model)),
              ("t", Json.num(ms)),
              (
                "items",
                Json.arr(
                  Array.map(SceneStream.items(m), item =>
                    Types.encodeReplyItem(toReplyItemPartial(item))
                  ),
                ),
              ),
            ]),
          )
          let outputPath = writeRawEvents(config.dataDir, sceneId, rawEvents)
          let reply = await buildSceneReply(
            ~config,
            ~model,
            ~sentWidth,
            ~sentHeight,
            ~serverStart=startMs,
            ~claudeMs=ms,
            ~sceneId,
            ~outputPath,
            ~items=SceneStream.items(m),
            ~usage=SceneStream.usage(m),
            ~quarterSeen=SceneStream.quarterSeen(m),
          )
          write(ScanEvent.Scene(reply))
          write(ScanEvent.End({t: elapsedMs(), status: ScanEvent.EndStatus.Timeout}))
        }
      | ClaudeStream.HttpFailed(status, text) => {
          let ms = elapsedMs()
          let msg = "Claude request failed (" ++ Int.toString(status) ++ "): " ++ text
          write(ScanEvent.ErrorEvent({t: ms, message: msg}))
          write(ScanEvent.End({t: ms, status: ScanEvent.EndStatus.Failed}))
        }
      | ClaudeStream.NoApiKey => {
          let ms = elapsedMs()
          write(
            ScanEvent.ErrorEvent({t: ms, message: "no ANTHROPIC_API_KEY set and FIXTURES is not 1"}),
          )
          write(ScanEvent.End({t: ms, status: ScanEvent.EndStatus.Failed}))
        }
      }
    }
  }
