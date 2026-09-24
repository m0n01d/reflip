// Domain types shared by the Claude client, the eBay client, the server, and
// the tests. Free of HTTP and file-system concerns.

type claudeItem = {
  name: string,
  maker: option<string>,
  query: string,
  estimateLowUsd: float,
  estimateHighUsd: float,
  basis: string,
  confidence: float,
  sources: array<string>,
}

type ebayStats = {
  count: int,
  minUsd: float,
  p25Usd: float,
  medianUsd: float,
  p75Usd: float,
  maxUsd: float,
}

type replyItem = {
  name: string,
  query: string,
  confidence: float,
  estimateLowUsd: float,
  estimateHighUsd: float,
  basis: string,
  sources: array<string>,
  ebay: option<ebayStats>,
  soldSearchUrl: string,
}

type usage = {
  inputTokens: int,
  outputTokens: int,
  cacheReadInputTokens: int,
  cacheCreationInputTokens: int,
  webSearchRequests: int,
}

type timing = {
  serverMs: float,
  claudeMs: float,
  ebayMs: float,
}

type cost = {
  usd: float,
  inputTokens: int,
  outputTokens: int,
  cacheReadTokens: int,
  cacheWriteTokens: int,
  webSearches: int,
}

type sceneReply = {
  sceneId: string,
  model: string,
  fixture: bool,
  outputPath: string,
  items: array<replyItem>,
  timing: timing,
  cost: cost,
  // Additive beyond the brief's reply shape: null unless the eBay stats
  // were skipped, in which case this says why. See reflip's CLAUDE.md.
  ebayNote: option<string>,
}

// -- JSON encoding (the only direction the HTTP reply needs) --------------

let encodeEbayStats = (s: ebayStats): JSON.t =>
  Json.obj([
    ("count", Json.num(Int.toFloat(s.count))),
    ("minUsd", Json.num(s.minUsd)),
    ("p25Usd", Json.num(s.p25Usd)),
    ("medianUsd", Json.num(s.medianUsd)),
    ("p75Usd", Json.num(s.p75Usd)),
    ("maxUsd", Json.num(s.maxUsd)),
  ])

let encodeReplyItem = (it: replyItem): JSON.t =>
  Json.obj([
    ("name", Json.str(it.name)),
    ("query", Json.str(it.query)),
    ("confidence", Json.num(it.confidence)),
    ("estimateLowUsd", Json.num(it.estimateLowUsd)),
    ("estimateHighUsd", Json.num(it.estimateHighUsd)),
    ("basis", Json.str(it.basis)),
    ("sources", Json.arr(Array.map(it.sources, Json.str))),
    (
      "ebay",
      switch it.ebay {
      | Some(s) => encodeEbayStats(s)
      | None => JSON.Encode.null
      },
    ),
    ("soldSearchUrl", Json.str(it.soldSearchUrl)),
  ])

let encodeTiming = (t: timing): JSON.t =>
  Json.obj([
    ("serverMs", Json.num(t.serverMs)),
    ("claudeMs", Json.num(t.claudeMs)),
    ("ebayMs", Json.num(t.ebayMs)),
  ])

let encodeCost = (c: cost): JSON.t =>
  Json.obj([
    ("usd", Json.num(c.usd)),
    ("inputTokens", Json.num(Int.toFloat(c.inputTokens))),
    ("outputTokens", Json.num(Int.toFloat(c.outputTokens))),
    ("cacheReadTokens", Json.num(Int.toFloat(c.cacheReadTokens))),
    ("cacheWriteTokens", Json.num(Int.toFloat(c.cacheWriteTokens))),
    ("webSearches", Json.num(Int.toFloat(c.webSearches))),
  ])

let encodeSceneReply = (r: sceneReply): JSON.t =>
  Json.obj([
    ("sceneId", Json.str(r.sceneId)),
    ("model", Json.str(r.model)),
    ("fixture", Json.boolJ(r.fixture)),
    ("outputPath", Json.str(r.outputPath)),
    ("items", Json.arr(Array.map(r.items, encodeReplyItem))),
    ("timing", encodeTiming(r.timing)),
    ("cost", encodeCost(r.cost)),
    (
      "ebayNote",
      switch r.ebayNote {
      | Some(s) => Json.str(s)
      | None => JSON.Encode.null
      },
    ),
  ])
