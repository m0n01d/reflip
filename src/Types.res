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
  // Haul mode only (step 4): where the item sits in the photo. None for a
  // scene-mode reply.
  where: option<string>,
  // Raw [x1, y1, x2, y2] from Claude's reply, in pixels of the photo Claude
  // saw. Not yet validated, clamped, or rescaled — Box.decode does that
  // once the sent photo's size and the model's tier are known. Scene mode
  // only: the haul prompt asks for no box, so it is None there.
  box: option<array<float>>,
}

// A box in pixels of the photo the page sent (see Box.decode).
type box = {
  x1: int,
  y1: int,
  x2: int,
  y2: int,
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
  box: option<box>,
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

// -- Haul mode (docs/spec-haul-mode.md "Step 3: brain queue") -------------

type haulGem = {
  findId: string,
  sceneId: string,
  name: string,
  where: option<string>,
  estimateLowUsd: float,
  estimateHighUsd: float,
  confidence: float,
  soldSearchUrl: string,
  ebay: option<ebayStats>,
  box: option<box>,
  imageWidth: option<int>,
  imageHeight: option<int>,
}

type failedPhoto = {
  sceneId: string,
  error: string,
}

type haulCounts = {
  queued: int,
  running: int,
  valued: int,
  failed: int,
}

type haulStatus = {
  haulId: string,
  name: option<string>,
  startedAt: string,
  doneAt: option<string>,
  emailedAt: option<string>,
  costUsd: float,
  maxUsd: float,
  gemMinUsd: float,
  stopReason: option<string>,
  emailNote: option<string>,
  counts: haulCounts,
  gems: array<haulGem>,
  otherCount: int,
  failed: array<failedPhoto>,
}

type sceneReply = {
  sceneId: string,
  model: string,
  fixture: bool,
  outputPath: string,
  items: array<replyItem>,
  // The size, in pixels, of the photo the brain sent to Claude (before any
  // resize Claude applies on its side — see ImageSize.res). Each item's box
  // is already rescaled onto this size, so the page draws it with no math.
  imageWidth: int,
  imageHeight: int,
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

let encodeBox = (b: box): JSON.t =>
  Json.arr([
    Json.num(Int.toFloat(b.x1)),
    Json.num(Int.toFloat(b.y1)),
    Json.num(Int.toFloat(b.x2)),
    Json.num(Int.toFloat(b.y2)),
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
    (
      "box",
      switch it.box {
      | Some(b) => encodeBox(b)
      | None => JSON.Encode.null
      },
    ),
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
    ("imageWidth", Json.num(Int.toFloat(r.imageWidth))),
    ("imageHeight", Json.num(Int.toFloat(r.imageHeight))),
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

// -- Haul mode JSON encoding -------------------------------------------------

let encodeOptString = (v: option<string>): JSON.t =>
  switch v {
  | Some(s) => Json.str(s)
  | None => JSON.Encode.null
  }

let encodeHaulGem = (g: haulGem): JSON.t =>
  Json.obj([
    ("findId", Json.str(g.findId)),
    ("sceneId", Json.str(g.sceneId)),
    ("name", Json.str(g.name)),
    ("where", encodeOptString(g.where)),
    ("estimateLowUsd", Json.num(g.estimateLowUsd)),
    ("estimateHighUsd", Json.num(g.estimateHighUsd)),
    ("confidence", Json.num(g.confidence)),
    ("soldSearchUrl", Json.str(g.soldSearchUrl)),
    (
      "ebay",
      switch g.ebay {
      | Some(s) => encodeEbayStats(s)
      | None => JSON.Encode.null
      },
    ),
    (
      "box",
      switch g.box {
      | Some(b) => encodeBox(b)
      | None => JSON.Encode.null
      },
    ),
    (
      "imageWidth",
      switch g.imageWidth {
      | Some(w) => Json.num(Int.toFloat(w))
      | None => JSON.Encode.null
      },
    ),
    (
      "imageHeight",
      switch g.imageHeight {
      | Some(h) => Json.num(Int.toFloat(h))
      | None => JSON.Encode.null
      },
    ),
  ])

let encodeFailedPhoto = (f: failedPhoto): JSON.t =>
  Json.obj([("sceneId", Json.str(f.sceneId)), ("error", Json.str(f.error))])

let encodeHaulCounts = (c: haulCounts): JSON.t =>
  Json.obj([
    ("queued", Json.num(Int.toFloat(c.queued))),
    ("running", Json.num(Int.toFloat(c.running))),
    ("valued", Json.num(Int.toFloat(c.valued))),
    ("failed", Json.num(Int.toFloat(c.failed))),
  ])

let encodeHaulStatus = (s: haulStatus): JSON.t =>
  Json.obj([
    ("haulId", Json.str(s.haulId)),
    ("name", encodeOptString(s.name)),
    ("startedAt", Json.str(s.startedAt)),
    ("doneAt", encodeOptString(s.doneAt)),
    ("emailedAt", encodeOptString(s.emailedAt)),
    ("costUsd", Json.num(s.costUsd)),
    ("maxUsd", Json.num(s.maxUsd)),
    ("gemMinUsd", Json.num(s.gemMinUsd)),
    ("stopReason", encodeOptString(s.stopReason)),
    ("emailNote", encodeOptString(s.emailNote)),
    ("counts", encodeHaulCounts(s.counts)),
    ("gems", Json.arr(Array.map(s.gems, encodeHaulGem))),
    ("otherCount", Json.num(Int.toFloat(s.otherCount))),
    ("failed", Json.arr(Array.map(s.failed, encodeFailedPhoto))),
  ])
