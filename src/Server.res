// HTTP server for the reflip brain: one scene endpoint, an rtt log
// endpoint, a bare `/`, and (part B) static files under dist/. Binds
// 127.0.0.1 only — CLAUDE.md hard design rule 4 (tailscale serve proxies
// HTTPS to it later; never Funnel).

type startResult = {server: Node.HttpServer.server, port: int, store: Store.t}

let jsonResponse = (res: Node.HttpServer.response, status: int, json: JSON.t): unit => {
  Node.HttpServer.writeHead(res, status, Dict.fromArray([("Content-Type", "application/json")]))
  Node.HttpServer.endWithBody(res, JSON.stringify(json))
}

let textResponse = (
  res: Node.HttpServer.response,
  status: int,
  contentType: string,
  body: string,
): unit => {
  Node.HttpServer.writeHead(res, status, Dict.fromArray([("Content-Type", contentType)]))
  Node.HttpServer.endWithBody(res, body)
}

// `Node.HttpServer.endWithBody` only takes a string, which would corrupt a
// binary file (an icon) read via `readFileUtf8`. Same underlying JS method
// ("end"), a second typed binding for the Buffer overload.
@send external endWithBuffer: (Node.HttpServer.response, Node.Buffer.t) => unit = "end"

// Fixed content-type table for static files under dist/. Falls back to
// application/octet-stream for anything not listed.
let contentTypeFor = (path: string): string =>
  if String.endsWith(path, ".html") {
    "text/html"
  } else if String.endsWith(path, ".webmanifest") {
    "application/manifest+json"
  } else if String.endsWith(path, ".js") || String.endsWith(path, ".mjs") {
    "text/javascript"
  } else if String.endsWith(path, ".css") {
    "text/css"
  } else if String.endsWith(path, ".json") {
    "application/json"
  } else if String.endsWith(path, ".svg") {
    "image/svg+xml"
  } else if String.endsWith(path, ".png") {
    "image/png"
  } else if String.endsWith(path, ".ico") {
    "image/x-icon"
  } else {
    "application/octet-stream"
  }

let placeholderHtml = "<!doctype html><html><body>reflip brain is running. Part B (the PWA page) is not built yet.</body></html>"

let parseRttPath = (pathname: string): option<string> => {
  let parts = pathname->String.split("/")->Array.filter(s => s != "")
  if Array.length(parts) == 4 {
    let a = Array.getUnsafe(parts, 0)
    let b = Array.getUnsafe(parts, 1)
    let id = Array.getUnsafe(parts, 2)
    let c = Array.getUnsafe(parts, 3)
    a == "api" && b == "scene" && c == "rtt" ? Some(id) : None
  } else {
    None
  }
}

let handleRoot = (config: Config.t, res: Node.HttpServer.response): unit =>
  if Node.Fs.existsSync(config.distIndexPath) {
    textResponse(res, 200, "text/html", Node.Fs.readFileUtf8(config.distIndexPath, "utf8"))
  } else {
    textResponse(res, 200, "text/html", placeholderHtml)
  }

// GET for anything else: serve it from dist/ if it exists there. `Node.Path.join`
// does not sandbox to its first argument (a later ".." segment can walk back
// out — verified: path.join("/a/b", "/../../c") => "/c"), so this checks the
// resolved path still starts with distDir before ever touching the
// filesystem. In practice `pathname` already had any ".." collapsed by the
// WHATWG URL parser in `route` below, but that is this function's caller's
// business, not a reason to skip checking here too.
let handleStatic = (config: Config.t, pathname: string, res: Node.HttpServer.response): unit => {
  let resolved = Node.Path.join([config.distDir, pathname])
  if String.startsWith(resolved, config.distDir ++ "/") && Node.Fs.existsSync(resolved) {
    Node.HttpServer.writeHead(
      res,
      200,
      Dict.fromArray([("Content-Type", contentTypeFor(resolved))]),
    )
    endWithBuffer(res, Node.Fs.readFileBuffer(resolved))
  } else {
    textResponse(res, 404, "text/plain", "not found")
  }
}

let handleRtt = (
  config: Config.t,
  sceneId: string,
  body: Node.Buffer.t,
  res: Node.HttpServer.response,
): unit => {
  let text = Node.Buffer.toStringWithEncoding(body, "utf8")
  switch JSON.parseOrThrow(text) {
  | json => {
      let rttMs = Json.floatField(json, "rttMs")->Option.getOr(0.0)
      let resizeMs = Json.floatField(json, "resizeMs")->Option.getOr(0.0)
      let line = Json.obj([
        ("type", Json.str("rtt")),
        ("sceneId", Json.str(sceneId)),
        ("rttMs", Json.num(rttMs)),
        ("resizeMs", Json.num(resizeMs)),
        ("ts", Json.num(Date.now())),
      ])
      SceneLog.appendLine(config.dataDir, line)
      jsonResponse(res, 200, Json.obj([("ok", Json.boolJ(true))]))
    }
  | exception JsExn(_) =>
    jsonResponse(res, 400, Json.obj([("error", Json.str("invalid JSON body"))]))
  }
}

// -- Haul mode routes (docs/spec-haul-mode.md "The routes") -----------------

type haulRoute = CreateHaul | AddScene(string) | GetHaul(string) | MarkDone(string)

let parseHaulPath = (method: string, pathname: string): option<haulRoute> => {
  let parts = pathname->String.split("/")->Array.filter(s => s != "")
  switch (method, Array.length(parts)) {
  | ("POST", 2) =>
    let a = Array.getUnsafe(parts, 0)
    let b = Array.getUnsafe(parts, 1)
    a == "api" && b == "hauls" ? Some(CreateHaul) : None
  | ("POST", 4) => {
      let a = Array.getUnsafe(parts, 0)
      let b = Array.getUnsafe(parts, 1)
      let id = Array.getUnsafe(parts, 2)
      let c = Array.getUnsafe(parts, 3)
      if a == "api" && b == "hauls" {
        if c == "scenes" {
          Some(AddScene(id))
        } else if c == "done" {
          Some(MarkDone(id))
        } else {
          None
        }
      } else {
        None
      }
    }
  | ("GET", 3) => {
      let a = Array.getUnsafe(parts, 0)
      let b = Array.getUnsafe(parts, 1)
      let id = Array.getUnsafe(parts, 2)
      a == "api" && b == "hauls" ? Some(GetHaul(id)) : None
    }
  | _ => None
  }
}

// 1 to 64 characters of [A-Za-z0-9-], per "The routes" in the spec.
let isClientIdChar = (c: string): bool =>
  (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-"

let isValidClientId = (s: string): bool => {
  let len = String.length(s)
  len >= 1 && len <= 64 && Array.every(String.split(s, ""), isClientIdChar)
}

let errorJson = (res: Node.HttpServer.response, status: int, msg: string): unit =>
  jsonResponse(res, status, Json.obj([("error", Json.str(msg))]))

let haulStatusResponse = (
  config: Config.t,
  store: Store.t,
  haulId: string,
  status: int,
  res: Node.HttpServer.response,
): unit =>
  switch HaulStatus.build(store, config, haulId) {
  | Some(haulStatus) => jsonResponse(res, status, Types.encodeHaulStatus(haulStatus))
  | None => errorJson(res, 404, "no such haul")
  }

let handleCreateHaul = async (
  config: Config.t,
  store: Store.t,
  req: Node.HttpServer.request,
  res: Node.HttpServer.response,
): unit =>
  if !config.fixtures && config.anthropicApiKey == None {
    errorJson(res, 503, "no ANTHROPIC_API_KEY set and FIXTURES is not 1")
  } else {
    let body = await Node.HttpServer.readBody(req)
    let text = String.trim(Node.Buffer.toStringWithEncoding(body, "utf8"))
    let name = if text == "" {
      None
    } else {
      switch JSON.parseOrThrow(text) {
      | json => Json.stringField(json, "name")->Option.flatMap(n => n == "" ? None : Some(n))
      | exception JsExn(_) => None
      }
    }
    let haulId = Node.Crypto.randomUUID()
    let now = Date.toISOString(Date.make())
    Store.createHaul(store, ~haulId, ~name, ~now)->ignore
    haulStatusResponse(config, store, haulId, 201, res)
  }

let maxPhotoBytes = 15 * 1024 * 1024

// Shared by handleScene (/api/scene) and StreamRoute.handle
// (/api/scene/stream): runs the eBay merge and the box decode, in that
// order after Claude — CLAUDE.md hard rule 1, eBay numbers never reach the
// model — then assembles the reply both routes send. Takes sceneId and
// outputPath already computed rather than writing them itself: the
// streaming route has no single raw Claude JSON blob to hand SceneLog
// .writeRaw, since it writes its own data/raw/<sceneId>.events.jsonl
// instead (StreamRoute.res). Passed into StreamRoute as a parameter so
// that module does not need to depend on Server.res.
let buildSceneReply = async (
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
): Types.sceneReply => {
  let ebayStart = Date.now()
  let merged = await Promise.all(
    Array.mapWithIndex(items, (item, i) => EbayClient.statsFor(config, i, item)),
  )
  let ebayMs = Date.now() -. ebayStart
  let ebayNote = Array.filterMap(merged, ((_, note)) => note)->Array.get(0)
  // The box was decoded raw off Claude's reply; finishing it needs the sent
  // photo's size and the model's tier, both known only here. Falls back to
  // Sonnet 5's tier if `model` somehow is not one of Shared.allModels — it
  // always is, since it came from Shared.modelId in route below.
  let boxModel = Shared.parseModelId(model)->Option.getOr(Shared.defaultModel)
  let replyItems = Array.mapWithIndex(items, (item, i) => {
    let (ebay, _) = Array.getUnsafe(merged, i)
    {
      Types.name: item.name,
      query: item.query,
      confidence: item.confidence,
      estimateLowUsd: item.estimateLowUsd,
      estimateHighUsd: item.estimateHighUsd,
      basis: item.basis,
      sources: item.sources,
      ebay,
      soldSearchUrl: EbayClient.soldSearchUrl(item.query),
      size: item.size,
      box: Box.decode(item.box, ~sentWidth, ~sentHeight, ~model=boxModel),
    }
  })
  let cost = {
    Types.usd: Pricing.usdCost(~model, ~usage),
    inputTokens: usage.inputTokens,
    outputTokens: usage.outputTokens,
    cacheReadTokens: usage.cacheReadInputTokens,
    cacheWriteTokens: usage.cacheCreationInputTokens,
    webSearches: usage.webSearchRequests,
  }
  let serverMs = Date.now() -. serverStart
  {
    Types.sceneId,
    model,
    fixture: config.fixtures,
    outputPath,
    items: replyItems,
    imageWidth: sentWidth,
    imageHeight: sentHeight,
    timing: {Types.serverMs, claudeMs, ebayMs},
    cost,
    ebayNote,
    quarterSeen,
  }
}

let handleAddScene = async (
  config: Config.t,
  store: Store.t,
  worker: HaulWorker.t,
  haulId: string,
  req: Node.HttpServer.request,
  res: Node.HttpServer.response,
): unit =>
  switch Store.getHaul(store, haulId) {
  | None => errorJson(res, 404, "no such haul")
  | Some(haul) if haul.doneAt != None => errorJson(res, 409, "haul is done")
  | Some(_) => {
      let clientId = Dict.get(Node.HttpServer.headers(req), "x-client-id")->Option.getOr("")
      if !isValidClientId(clientId) {
        errorJson(res, 400, "x-client-id header must be 1 to 64 characters of [A-Za-z0-9-]")
      } else {
        switch Store.sceneByClient(store, ~haulId, ~clientId) {
        | Some(existing) =>
          jsonResponse(
            res,
            202,
            Json.obj([("sceneId", Json.str(existing.sceneId)), ("duplicate", Json.boolJ(true))]),
          )
        | None => {
            let body = await Node.HttpServer.readBody(req)
            let len = Node.Buffer.length(body)
            if len == 0 {
              errorJson(res, 400, "empty body")
            } else if len > maxPhotoBytes {
              errorJson(res, 413, "photo over 15 MB")
            } else {
              let sceneId = Node.Crypto.randomUUID()
              Node.Fs.mkdirSync(Node.Path.join([config.dataDir, "photos"]), {recursive: true})
              let photoPath = Node.Path.join([config.dataDir, "photos", sceneId ++ ".jpg"])
              Node.Fs.writeFileBuffer(photoPath, body)
              let now = Date.toISOString(Date.make())
              Store.addScene(store, ~haulId, ~clientId, ~sceneId, ~photoPath, ~now)->ignore
              HaulWorker.kick(worker)
              jsonResponse(res, 202, Json.obj([("sceneId", Json.str(sceneId))]))
            }
          }
        }
      }
    }
  }

let handleGetHaul = (
  config: Config.t,
  store: Store.t,
  haulId: string,
  res: Node.HttpServer.response,
): unit => haulStatusResponse(config, store, haulId, 200, res)

let handleMarkDone = (
  config: Config.t,
  store: Store.t,
  worker: HaulWorker.t,
  haulId: string,
  res: Node.HttpServer.response,
): unit =>
  switch Store.getHaul(store, haulId) {
  | None => errorJson(res, 404, "no such haul")
  | Some(_) => {
      let now = Date.toISOString(Date.make())
      Store.markDone(store, ~haulId, ~now)
      HaulWorker.checkDrained(worker, haulId)
      haulStatusResponse(config, store, haulId, 200, res)
    }
  }

let handleScene = async (
  config: Config.t,
  model: string,
  body: Node.Buffer.t,
  res: Node.HttpServer.response,
): unit =>
  switch JpegSize.dimensions(body) {
  | None =>
    jsonResponse(
      res,
      400,
      Json.obj([("error", Json.str("could not read the photo's width and height"))]),
    )
  | Some((sentWidth, sentHeight)) => {
      let serverStart = Date.now()
      let imageBase64 = Node.Buffer.toStringWithEncoding(body, "base64")
      let claudeStart = Date.now()
      switch (
        await ClaudeClient.call(
          ~config,
          ~model,
          ~imageBase64,
          ~mode=ClaudeClient.Scene({width: sentWidth, height: sentHeight}),
        )
      ) {
      | Error(ClaudeClient.NoApiKey) =>
        jsonResponse(
          res,
          503,
          Json.obj([("error", Json.str("no ANTHROPIC_API_KEY set and FIXTURES is not 1"))]),
        )
      | Error(ClaudeClient.HttpError(status, msg)) =>
        jsonResponse(
          res,
          502,
          Json.obj([
            ("error", Json.str("Claude request failed (" ++ Int.toString(status) ++ "): " ++ msg)),
          ]),
        )
      | Error(ClaudeClient.Timeout(ms)) => {
          let msg = "Claude took longer than " ++ Float.toString(Int.toFloat(ms) /. 1000.0) ++ " s"
          Console.error("reflip: " ++ msg ++ ", answering 504")
          jsonResponse(res, 504, Json.obj([("error", Json.str(msg))]))
        }
      | Error(ClaudeClient.DecodeFailed(_)) =>
        jsonResponse(res, 502, Json.obj([("error", Json.str("could not decode Claude's reply"))]))
      | Error(ClaudeClient.CutOff(raw)) => {
          let claudeMs = Date.now() -. claudeStart
          let sceneId = Node.Crypto.randomUUID()
          let outputPath = SceneLog.writeRaw(config.dataDir, sceneId, raw)
          let usage = ClaudeClient.usageOfResponse(raw)
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
              ("timing", Json.obj([("claudeMs", Json.num(claudeMs))])),
              ("cost", Types.encodeCost(cost)),
            ]),
          )
          Console.error(
            "reflip: scene " ++
            sceneId ++
            " cut off, " ++
            Int.toString(usage.outputTokens) ++
            " output tokens, " ++
            Int.toString(usage.webSearchRequests) ++
            " web searches, $" ++
            Float.toString(cost.usd),
          )
          jsonResponse(
            res,
            502,
            Json.obj([
              ("error", Json.str("reply cut off")),
              ("sceneId", Json.str(sceneId)),
            ]),
          )
        }
      | Ok(decoded) => {
          let claudeMs = Date.now() -. claudeStart
          let sceneId = Node.Crypto.randomUUID()
          let outputPath = SceneLog.writeRaw(config.dataDir, sceneId, decoded.raw)
          let reply = await buildSceneReply(
            ~config,
            ~model,
            ~sentWidth,
            ~sentHeight,
            ~serverStart,
            ~claudeMs,
            ~sceneId,
            ~outputPath,
            ~items=decoded.items,
            ~usage=decoded.usage,
            ~quarterSeen=decoded.quarterSeen,
          )
          SceneLog.appendLine(config.dataDir, Types.encodeSceneReply(reply))
          jsonResponse(res, 200, Types.encodeSceneReply(reply))
        }
      }
    }
  }

let route = async (
  config: Config.t,
  store: Store.t,
  worker: HaulWorker.t,
  req: Node.HttpServer.request,
  res: Node.HttpServer.response,
) => {
  let method = Node.HttpServer.method(req)
  let url = Node.Url.make(Node.HttpServer.url(req), "http://127.0.0.1")
  let pathname = Node.Url.pathname(url)
  switch parseHaulPath(method, pathname) {
  | Some(CreateHaul) => await handleCreateHaul(config, store, req, res)
  | Some(AddScene(haulId)) => await handleAddScene(config, store, worker, haulId, req, res)
  | Some(GetHaul(haulId)) => handleGetHaul(config, store, haulId, res)
  | Some(MarkDone(haulId)) => handleMarkDone(config, store, worker, haulId, res)
  | None =>
  if method == "GET" && pathname == "/" {
    handleRoot(config, res)
  } else if method == "POST" && pathname == "/api/scene/stream" {
    let rawModel = Node.Url.searchParams(url)->Node.Url.getParam("model")->Nullable.toOption
    switch rawModel {
    | Some(id) =>
      switch Shared.parseModelId(id) {
      | Some(m) => {
          let body = await Node.HttpServer.readBody(req)
          await StreamRoute.handle(~config, ~model=Shared.modelId(m), ~body, ~res, ~buildSceneReply)
        }
      | None =>
        jsonResponse(
          res,
          400,
          Json.obj([
            ("error", Json.str("unknown model id: " ++ id)),
            (
              "validModels",
              Json.arr(Shared.allModels->Array.map(m => Json.str(Shared.modelId(m)))),
            ),
          ]),
        )
      }
    | None => {
        let body = await Node.HttpServer.readBody(req)
        await StreamRoute.handle(
          ~config,
          ~model=Shared.modelId(Shared.defaultModel),
          ~body,
          ~res,
          ~buildSceneReply,
        )
      }
    }
  } else if method == "POST" && pathname == "/api/scene" {
    let rawModel = Node.Url.searchParams(url)->Node.Url.getParam("model")->Nullable.toOption
    switch rawModel {
    | Some(id) =>
      switch Shared.parseModelId(id) {
      | Some(m) => {
          let body = await Node.HttpServer.readBody(req)
          await handleScene(config, Shared.modelId(m), body, res)
        }
      | None =>
        jsonResponse(
          res,
          400,
          Json.obj([
            ("error", Json.str("unknown model id: " ++ id)),
            (
              "validModels",
              Json.arr(Shared.allModels->Array.map(m => Json.str(Shared.modelId(m)))),
            ),
          ]),
        )
      }
    | None => {
        let body = await Node.HttpServer.readBody(req)
        await handleScene(config, Shared.modelId(Shared.defaultModel), body, res)
      }
    }
  } else if method == "GET" {
    handleStatic(config, pathname, res)
  } else {
    switch parseRttPath(pathname) {
    | Some(sceneId) if method == "POST" => {
        let body = await Node.HttpServer.readBody(req)
        handleRtt(config, sceneId, body, res)
      }
    | _ => textResponse(res, 404, "text/plain", "not found")
    }
  }
  }
}

let start = (config: Config.t): promise<startResult> =>
  Promise.make((resolve, _reject) => {
    Node.Fs.mkdirSync(config.dataDir, {recursive: true})
    let store = Store.openAt(Node.Path.join([config.dataDir, "reflip.db"]))
    let resetCount = Store.resetRunning(store)
    if resetCount > 0 {
      Console.log(
        "reflip: reset " ++ Int.toString(resetCount) ++ " running scene(s) back to queued",
      )
    }
    let worker = HaulWorker.make(~config, ~store, ~onDrained=haulId => {
      Console.log("reflip: haul " ++ haulId ++ " drained")
      HaulEmail.send(config, store, haulId)
    })
    let server = Node.HttpServer.createServer((req, res) =>
      route(config, store, worker, req, res)
      ->Promise.catch(
        err => {
          Console.error2("reflip: unhandled error", err)
          // StreamRoute.handle can already have sent the SSE 200 headers
          // before a rejection like this one arrives — once that happened,
          // writeHead (inside textResponse) throws ERR_HTTP_HEADERS_SENT
          // instead of answering, and that used to crash the process. All
          // that is left to do at that point is end the response.
          if Node.HttpServer.headersSent(res) {
            if !Node.HttpServer.writableEnded(res) {
              Node.HttpServer.endWithBody(res, "")
            }
          } else {
            textResponse(res, 500, "text/plain", "internal error")
          }
          Promise.resolve()
        },
      )
      ->Promise.ignore
    )
    Node.HttpServer.listen(server, config.port, "127.0.0.1", () => {
      HaulWorker.kick(worker)
      resolve({server, port: Node.HttpServer.address(server).port, store})
    })
  })
