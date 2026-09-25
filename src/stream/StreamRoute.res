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
  // Hard design rule 5: outside FIXTURES=1, a missing Anthropic key is a
  // 503 with the same body handleScene sends for ClaudeClient.NoApiKey.
  // Checked before any header goes out — ClaudeStream.run would report
  // this same case as its own NoApiKey outcome later, but by then the SSE
  // 200 headers are already on the wire and a 503 is no longer possible.
  if !config.fixtures && config.anthropicApiKey == None {
    jsonError(res, 503, "no ANTHROPIC_API_KEY set and FIXTURES is not 1")
  } else {
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

        // The spot pass (docs/scan-ui.md §1 decision 1): a second, toolless
        // Claude call over the same photo, started right away so stickers
        // land on the photo in seconds instead of near the end. It shares
        // `controller`'s signal with the priced call below, so the same stop
        // request or time limit reaches both, and so that once the priced
        // pass ends, aborting `controller` again (see `finishSpot`) also
        // cuts off a spot pass that is still running. A spot failure only
        // ever writes spot-failed — it never touches the priced scene.
        let spotUsageRef: ref<option<Types.usage>> = ref(None)

        let onSpotEvent = (ms: float, evt: SpotPass.logEvent): unit =>
          switch evt {
          | SpotPass.Started({inputTokens}) => write(ScanEvent.SpotStarted({t: ms, inputTokens}))
          | SpotPass.ItemFound({index, name, box}) =>
            write(ScanEvent.SpotItem({t: ms, index, name, box}))
          | SpotPass.Finished({usage}) => {
              spotUsageRef := Some(usage)
              write(
                ScanEvent.SpotDone({
                  t: ms,
                  claudeMs: ms,
                  inputTokens: usage.inputTokens,
                  outputTokens: usage.outputTokens,
                  usd: Pricing.usdCost(~model, ~usage),
                }),
              )
            }
          | SpotPass.Failed(message) => write(ScanEvent.SpotFailed({t: ms, message}))
          }

        let spotPromise = SpotPass.run(
          ~config,
          ~buildBody=(~structuredOutput) =>
            SpotPass.buildRequestBody(
              ~model,
              ~imageBase64,
              ~structuredOutput,
              ~width=sentWidth,
              ~height=sentHeight,
            ),
          ~stop=Fetch.AbortController.signal(controller),
          ~onEvent=onSpotEvent,
          ~onRaw=(_ms, _sseEvt) => (),
        )
        // SpotPass.runLive already turns a failed live call into a
        // StreamError outcome, so this promise seldom rejects. It still can
        // in fixture mode (a fixture file that fails to read, for example).
        // If the catch around the priced pass below ends the scene before
        // finishSpot awaits this promise, that rejection would reach Node
        // unhandled and stop the process. This observer only guards against
        // that crash. finishSpot still awaits the real spotPromise and sees
        // its real value.
        spotPromise->Promise.catch(_ => Promise.resolve(SpotPass.NoApiKey))->ignore

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

        // Aborts the spot pass if it is still running (docs/scan-ui.md
        // brief: "when the priced pass ends, abort a spot pass that still
        // runs"), then waits for it so any trailing spot event is written
        // before `end`. Safe to call when `controller` is already aborted
        // (a Stop request or the time limit got there first) — abort on an
        // already-aborted AbortController is a no-op. Call this once, right
        // before every `write(ScanEvent.End(...))` below.
        let finishSpot = async (): unit => {
          Fetch.AbortController.abort(controller)
          switch await spotPromise {
          | SpotPass.Completed(_) | SpotPass.Stopped(_) => ()
          | SpotPass.TimedOut(_, timeoutMs) =>
            write(
              ScanEvent.SpotFailed({
                t: elapsedMs(),
                message: "the spot pass took longer than " ++
                Float.toString(Int.toFloat(timeoutMs) /. 1000.0) ++ " s",
              }),
            )
          | SpotPass.HttpFailed(status, text) =>
            write(
              ScanEvent.SpotFailed({
                t: elapsedMs(),
                message: "spot request failed (" ++ Int.toString(status) ++ "): " ++ text,
              }),
            )
          | SpotPass.NoApiKey =>
            write(
              ScanEvent.SpotFailed({
                t: elapsedMs(),
                message: "no ANTHROPIC_API_KEY set and FIXTURES is not 1",
              }),
            )
          | SpotPass.NoFixture(message) => write(ScanEvent.SpotFailed({t: elapsedMs(), message}))
          | SpotPass.StreamError(_, message) =>
            write(ScanEvent.SpotFailed({t: elapsedMs(), message}))
          }
          // Logged as its own line, tagged with the same sceneId, rather
          // than spliced into the scene line below: that line's JSON comes
          // from Types.encodeSceneReply in the normal-completion branch,
          // which is outside this file.
          switch spotUsageRef.contents {
          | None => ()
          | Some(usage) =>
            SceneLog.appendLine(
              config.dataDir,
              Json.obj([
                ("sceneId", Json.str(sceneId)),
                ("spotInputTokens", Json.num(Int.toFloat(usage.inputTokens))),
                ("spotOutputTokens", Json.num(Int.toFloat(usage.outputTokens))),
                ("spotUsd", Json.num(Pricing.usdCost(~model, ~usage))),
              ]),
            )
          }
        }

        // buildSceneReply's eBay merge (Promise.all over EbayClient.statsFor)
        // can reject outside fixture mode — EbayClient.res itself catches
        // nothing (a bad key, a dropped connection). Without this try, that
        // rejection used to escape all the way to Server.res's server-level
        // handler after the 200 SSE headers were already sent, which threw
        // ERR_HTTP_HEADERS_SENT and crashed the process.
        let tryBuildSceneReply = async (
          ~claudeMs: float,
          ~outputPath: string,
          ~items: array<Types.claudeItem>,
          ~usage: Types.usage,
          ~quarterSeen: bool,
        ): result<Types.sceneReply, string> =>
          try {
            let reply = await buildSceneReply(
              ~config,
              ~model,
              ~sentWidth,
              ~sentHeight,
              ~serverStart=startMs,
              ~claudeMs,
              ~sceneId,
              ~outputPath,
              ~items,
              ~usage,
              ~quarterSeen,
            )
            Ok(reply)
          } catch {
          | JsExn(e) => Error(JsExn.message(e)->Option.getOr("unknown error"))
          }

        // A failed eBay merge still owes the registry scene its `error`,
        // then `end {status: failed}`, so a page that reconnects ends cleanly.
        let endFailed = async (message: string): unit => {
          write(ScanEvent.ErrorEvent({t: elapsedMs(), message}))
          await finishSpot()
          write(ScanEvent.End({t: elapsedMs(), status: ScanEvent.EndStatus.Failed}))
        }

        // The last-resort catch for this scene. ClaudeStream.run turns a
        // failed Claude call into its StreamError outcome, and
        // tryBuildSceneReply catches a failed eBay merge, so neither one
        // reaches this catch. Anything else that throws from here on (a
        // failed write of the raw events file or of a scene log line, for
        // example) still ends the scene: `error`, then `end {status:
        // failed}`. Without this catch, the scene stayed Running with no
        // `end`, and the rejection reached Server.res's top-level catch.
        try {
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
                await finishSpot()
                write(ScanEvent.End({t: ms, status: ScanEvent.EndStatus.Failed}))
              }
            | None => {
                let outputPath = writeRawEvents(config.dataDir, sceneId, rawEvents)
                switch await tryBuildSceneReply(
                  ~claudeMs=claudeMsRef.contents,
                  ~outputPath,
                  ~items=SceneStream.items(m),
                  ~usage=SceneStream.usage(m),
                  ~quarterSeen=SceneStream.quarterSeen(m),
                ) {
                | Ok(reply) => {
                    SceneLog.appendLine(config.dataDir, Types.encodeSceneReply(reply))
                    write(ScanEvent.Scene(reply))
                    await finishSpot()
                    write(ScanEvent.End({t: elapsedMs(), status: ScanEvent.EndStatus.Done}))
                  }
                | Error(message) => await endFailed(message)
                }
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
                    Json.arr(
                      Array.map(items, item => Types.encodeReplyItem(toReplyItemPartial(item))),
                    ),
                  ),
                ]),
              )
              let outputPath = writeRawEvents(config.dataDir, sceneId, rawEvents)
              switch await tryBuildSceneReply(
                ~claudeMs=ms,
                ~outputPath,
                ~items,
                ~usage=SceneStream.usage(m),
                ~quarterSeen=SceneStream.quarterSeen(m),
              ) {
              | Ok(reply) => {
                  write(ScanEvent.Scene(reply))
                  await finishSpot()
                  write(ScanEvent.End({t: elapsedMs(), status: ScanEvent.EndStatus.Stopped}))
                }
              | Error(message) => await endFailed(message)
              }
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
              switch await tryBuildSceneReply(
                ~claudeMs=ms,
                ~outputPath,
                ~items=SceneStream.items(m),
                ~usage=SceneStream.usage(m),
                ~quarterSeen=SceneStream.quarterSeen(m),
              ) {
              | Ok(reply) => {
                  write(ScanEvent.Scene(reply))
                  await finishSpot()
                  write(ScanEvent.End({t: elapsedMs(), status: ScanEvent.EndStatus.Timeout}))
                }
              | Error(message) => await endFailed(message)
              }
            }
          | ClaudeStream.HttpFailed(status, text) => {
              let ms = elapsedMs()
              let msg = "Claude request failed (" ++ Int.toString(status) ++ "): " ++ text
              write(ScanEvent.ErrorEvent({t: ms, message: msg}))
              await finishSpot()
              write(ScanEvent.End({t: ms, status: ScanEvent.EndStatus.Failed}))
            }
          | ClaudeStream.NoApiKey => {
              let ms = elapsedMs()
              write(
                ScanEvent.ErrorEvent({
                  t: ms,
                  message: "no ANTHROPIC_API_KEY set and FIXTURES is not 1",
                }),
              )
              await finishSpot()
              write(ScanEvent.End({t: ms, status: ScanEvent.EndStatus.Failed}))
            }
          // A dropped connection or any other exception mid-stream:
          // ClaudeStream.run resolves this instead of rejecting. The registry
          // scene still gets `error`, then `end {status: failed}`, so a page
          // that reconnects through GET /api/scene/:id/events ends cleanly.
          | ClaudeStream.StreamError(_, msg) => {
              let ms = elapsedMs()
              write(ScanEvent.ErrorEvent({t: ms, message: msg}))
              await finishSpot()
              write(ScanEvent.End({t: ms, status: ScanEvent.EndStatus.Failed}))
            }
          }
        } catch {
        | JsExn(e) => {
            // Stops a spot pass that still runs, as finishSpot does on every
            // other path. finishSpot itself is not called here, because it
            // can be the part that threw.
            Fetch.AbortController.abort(controller)
            let ms = elapsedMs()
            let message = JsExn.message(e)->Option.getOr("unknown error")
            write(ScanEvent.ErrorEvent({t: ms, message: "scene failed: " ++ message}))
            write(ScanEvent.End({t: ms, status: ScanEvent.EndStatus.Failed}))
          }
        }
      }
    }
  }
