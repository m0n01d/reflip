// HTTP server for the reflip brain: one scene endpoint, an rtt log
// endpoint, a bare `/`, and (part B) static files under dist/. Binds
// 127.0.0.1 only — CLAUDE.md hard design rule 4 (tailscale serve proxies
// HTTPS to it later; never Funnel).

type startResult = {server: Node.HttpServer.server, port: int}

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
    Node.HttpServer.writeHead(res, 200, Dict.fromArray([("Content-Type", contentTypeFor(resolved))]))
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

// One item's eBay merge. Fixture mode reads tests/fixtures/ebay-search-<n>;
// real mode calls the Browse API. Missing eBay keys (non-fixture) mean the
// stats are null and the returned note says why (surfaced as the reply's
// top-level `ebayNote`).
let mergeEbay = async (config: Config.t, index: int, item: Types.claudeItem) =>
  if config.fixtures {
    (EbayClient.decodeStats(EbayClient.searchFixture(config.fixturesDir, index)), None)
  } else {
    switch (config.ebayClientId, config.ebayClientSecret) {
    | (Some(id), Some(secret)) =>
      switch await EbayClient.fetchToken(~clientId=id, ~clientSecret=secret) {
      | Ok(token) =>
        switch await EbayClient.search(~accessToken=token, ~query=item.query) {
        | Ok(json) => (EbayClient.decodeStats(json), None)
        | Error(msg) => (None, Some("eBay search failed: " ++ msg))
        }
      | Error(msg) => (None, Some("eBay auth failed: " ++ msg))
      }
    | _ => (None, Some("eBay stats disabled: set EBAY_CLIENT_ID and EBAY_CLIENT_SECRET"))
    }
  }

let handleScene = async (
  config: Config.t,
  model: string,
  body: Node.Buffer.t,
  res: Node.HttpServer.response,
): unit => {
  let serverStart = Date.now()
  let imageBase64 = Node.Buffer.toStringWithEncoding(body, "base64")
  let claudeStart = Date.now()
  switch await ClaudeClient.call(~config, ~model, ~imageBase64) {
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
  | Error(ClaudeClient.DecodeFailed(_)) =>
    jsonResponse(res, 502, Json.obj([("error", Json.str("could not decode Claude's reply"))]))
  | Ok(decoded) => {
      let claudeMs = Date.now() -. claudeStart
      let ebayStart = Date.now()
      let merged = await Promise.all(
        Array.mapWithIndex(decoded.items, (item, i) => mergeEbay(config, i, item)),
      )
      let ebayMs = Date.now() -. ebayStart
      let ebayNote = Array.filterMap(merged, ((_, note)) => note)->Array.get(0)
      let items = Array.mapWithIndex(decoded.items, (item, i) => {
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
        }
      })
      let sceneId = Node.Crypto.randomUUID()
      let cost = {
        Types.usd: Pricing.usdCost(~model, ~usage=decoded.usage),
        inputTokens: decoded.usage.inputTokens,
        outputTokens: decoded.usage.outputTokens,
        cacheReadTokens: decoded.usage.cacheReadInputTokens,
        cacheWriteTokens: decoded.usage.cacheCreationInputTokens,
        webSearches: decoded.usage.webSearchRequests,
      }
      let outputPath = SceneLog.writeRaw(config.dataDir, sceneId, decoded.raw)
      let serverMs = Date.now() -. serverStart
      let reply: Types.sceneReply = {
        Types.sceneId,
        model,
        fixture: config.fixtures,
        outputPath,
        items,
        timing: {Types.serverMs, claudeMs, ebayMs},
        cost,
        ebayNote,
      }
      SceneLog.appendLine(config.dataDir, Types.encodeSceneReply(reply))
      jsonResponse(res, 200, Types.encodeSceneReply(reply))
    }
  }
}

let route = async (config: Config.t, req: Node.HttpServer.request, res: Node.HttpServer.response) => {
  let method = Node.HttpServer.method(req)
  let url = Node.Url.make(Node.HttpServer.url(req), "http://127.0.0.1")
  let pathname = Node.Url.pathname(url)
  if method == "GET" && pathname == "/" {
    handleRoot(config, res)
  } else if method == "POST" && pathname == "/api/scene" {
    let body = await Node.HttpServer.readBody(req)
    let model =
      Node.Url.searchParams(url)
      ->Node.Url.getParam("model")
      ->Nullable.toOption
      ->Option.flatMap(Shared.parseModelId)
      ->Option.getOr(Shared.defaultModel)
      ->Shared.modelId
    await handleScene(config, model, body, res)
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

let start = (config: Config.t): promise<startResult> =>
  Promise.make((resolve, _reject) => {
    let server = Node.HttpServer.createServer((req, res) =>
      route(config, req, res)
      ->Promise.catch(err => {
          Console.error2("reflip: unhandled error", err)
          textResponse(res, 500, "text/plain", "internal error")
          Promise.resolve()
        })
      ->Promise.ignore
    )
    Node.HttpServer.listen(server, config.port, "127.0.0.1", () =>
      resolve({server, port: Node.HttpServer.address(server).port})
    )
  })
