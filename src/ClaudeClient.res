// Claude Messages API client: request building, response decode, and the
// fixture-mode short-circuit. Request shape checked against the claude-api
// skill on 2026-09-24 (see reflip's CLAUDE.md, "Claude API facts").
//
// Hard design rule: eBay numbers never reach the model (CLAUDE.md rule 1).
// This module never opens or calls EbayClient — GuardTest.res checks the
// built request body for eBay fixture titles and prices.

type decodeError = EmptyContent | NoJsonFound | InvalidJson(string) | SchemaMismatch(string)

type decoded = {
  items: array<Types.claudeItem>,
  usage: Types.usage,
  // Haul mode only (step 4): how many other, unlisted items the model saw.
  // None for a scene-mode reply, or any reply whose JSON left it out.
  otherCount: option<int>,
  raw: JSON.t,
  // Scene mode only: true if the model reported a quarter in the photo.
  // False when the reply's JSON left the field out (haul mode, or an
  // older log line).
  quarterSeen: bool,
}

type callError = NoApiKey | HttpError(int, string) | DecodeFailed(decodeError) | Timeout(int) | CutOff(JSON.t)

// Scene mode is the single-photo M0 endpoint. It carries the width and the
// height of the sent photo, so the prompt can ask for a box per item in
// pixels of that photo (docs/spec-item-boxes.md). Haul is the haul queue
// (step 4): a different prompt and schema, gated on the same $ floor
// HaulStatus and HaulWorker use to decide what counts as a gem. The haul
// prompt now asks for a box too (docs/spec-item-boxes.md's follow-up), so it
// carries the sent photo's width and height, same as Scene.
type mode = Scene({width: int, height: int}) | Haul({gemMinUsd: float, width: int, height: int})

let decodeUsage = (json: JSON.t): Types.usage => {
  let webSearchRequests =
    Json.field(json, "server_tool_use")
    ->Option.flatMap(stu => Json.intField(stu, "web_search_requests"))
    ->Option.getOr(0)
  {
    Types.inputTokens: Json.intField(json, "input_tokens")->Option.getOr(0),
    outputTokens: Json.intField(json, "output_tokens")->Option.getOr(0),
    cacheReadInputTokens: Json.intField(json, "cache_read_input_tokens")->Option.getOr(0),
    cacheCreationInputTokens: Json.intField(json, "cache_creation_input_tokens")->Option.getOr(0),
    webSearchRequests,
  }
}

let isToolResultBlockType = (t: string): bool => String.endsWith(t, "_tool_result")

// Join the text blocks after the last tool-result block, per CLAUDE.md's
// decode rule. When there is no tool-result block (no search happened), use
// every text block.
let extractJsonText = (blocks: array<JSON.t>): option<string> => {
  let lastToolResultIdx = Array.reduceWithIndex(blocks, -1, (acc, block, i) =>
    switch Json.stringField(block, "type") {
    | Some(t) if isToolResultBlockType(t) => i
    | _ => acc
    }
  )
  let relevant = Array.slice(blocks, ~start=lastToolResultIdx + 1)
  let texts = Array.filterMap(relevant, block =>
    switch Json.stringField(block, "type") {
    | Some("text") => Json.stringField(block, "text")
    | _ => None
    }
  )
  Array.length(texts) == 0 ? None : Some(Array.join(texts, ""))
}

let decodeItem = (json: JSON.t): result<Types.claudeItem, string> =>
  switch (
    Json.stringField(json, "name"),
    Json.stringField(json, "query"),
    Json.stringField(json, "basis"),
    Json.floatField(json, "estimateLowUsd"),
    Json.floatField(json, "estimateHighUsd"),
    Json.floatField(json, "confidence"),
  ) {
  | (Some(name), Some(query), Some(basis), Some(low), Some(high), Some(confidence)) =>
    let maker = Json.stringField(json, "maker")->Option.flatMap(m => m == "" ? None : Some(m))
    let sources =
      Json.arrayField(json, "sources")
      ->Option.map(arr => Array.filterMap(arr, JSON.Decode.string))
      ->Option.getOr([])
    // Left raw here — Box.decode does the geometric validation, clamp, and
    // rescale once the sent photo's size and the model's tier are known.
    let box = Json.arrayField(json, "box")->Option.map(arr => Array.filterMap(arr, JSON.Decode.float))
    Ok({
      Types.name,
      maker,
      query,
      estimateLowUsd: low,
      estimateHighUsd: high,
      basis,
      confidence,
      sources,
      where: Json.stringField(json, "where"),
      size: Json.stringField(json, "size")->Option.getOr(""),
      box,
    })
  | _ => Error("item missing a required field")
  }

let decodeItemsJson = (json: JSON.t): result<array<Types.claudeItem>, decodeError> =>
  switch Json.arrayField(json, "items") {
  | None => Error(SchemaMismatch("no items array"))
  | Some(arr) => Array.map(arr, decodeItem)->Result.all->Result.mapError(msg => SchemaMismatch(msg))
  }

// Public so the CutOff callError (a reply cut short before decodeResponse
// ever runs) can still recover its usage — the scene route logs the cost of
// a cut-off reply the same way it logs a decoded one.
let usageOfResponse = (responseJson: JSON.t): Types.usage => {
  let emptyUsage: Types.usage = {
    inputTokens: 0,
    outputTokens: 0,
    cacheReadInputTokens: 0,
    cacheCreationInputTokens: 0,
    webSearchRequests: 0,
  }
  Json.field(responseJson, "usage")->Option.map(decodeUsage)->Option.getOr(emptyUsage)
}

// A decode failure is an error variant, never a crash: JSON.parseOrThrow's
// SyntaxError is caught with the `exception JsExn(_)` arm below, and every
// other branch is total over its input.
let decodeResponse = (responseJson: JSON.t): result<decoded, decodeError> => {
  let usage = usageOfResponse(responseJson)
  switch Json.arrayField(responseJson, "content") {
  | None => Error(EmptyContent)
  | Some(blocks) =>
    switch extractJsonText(blocks) {
    | None => Error(EmptyContent)
    | Some(text) =>
      switch JSON.parseOrThrow(text) {
      | parsed =>
        decodeItemsJson(parsed)->Result.map(items => {
          items,
          usage,
          otherCount: Json.intField(parsed, "otherCount"),
          raw: responseJson,
          quarterSeen: Json.boolField(parsed, "quarterSeen")->Option.getOr(false),
        })
      | exception JsExn(_) =>
        switch Json.firstJsonObjectSpan(text) {
        | None => Error(NoJsonFound)
        | Some(span) =>
          switch JSON.parseOrThrow(span) {
          | parsed2 =>
            decodeItemsJson(parsed2)->Result.map(items => {
              items,
              usage,
              otherCount: Json.intField(parsed2, "otherCount"),
              raw: responseJson,
              quarterSeen: Json.boolField(parsed2, "quarterSeen")->Option.getOr(false),
            })
          | exception JsExn(_) => Error(InvalidJson(text))
          }
        }
      }
    }
  }
}

// Wraps decodeResponse with the one check decodeResponse cannot make on its
// own: a reply Claude cut short (stop_reason "max_tokens") is not a decode
// failure, it is a different callError, so the worker and /api/scene can
// both give it its own message ("reply cut off") instead of the generic
// decode-failed one.
let parseClaudeJson = (json: JSON.t): result<decoded, callError> =>
  if Json.stringField(json, "stop_reason") == Some("max_tokens") {
    Error(CutOff(json))
  } else {
    switch decodeResponse(json) {
    | Ok(d) => Ok(d)
    | Error(e) => Error(DecodeFailed(e))
    }
  }

let systemTextFor = (mode: mode): string =>
  switch mode {
  | Scene(_) => SystemPrompt.text
  | Haul({gemMinUsd}) => SystemPrompt.haulPrompt(~gemMinUsd)
  }

let outputFormatFor = (mode: mode): JSON.t =>
  switch mode {
  | Scene(_) => SystemPrompt.outputFormat
  | Haul(_) => SystemPrompt.haulOutputFormat
  }

// Sonnet 5 thinks by default (adaptive thinking), and its thinking tokens
// count against max_tokens. On 2026-09-25 a 43-item scene used 7,583 output
// tokens (2,300 of them thinking), and an earlier call on the same photo hit
// the old 8192 cap. Only generated tokens bill, so the higher cap costs
// nothing on a scene that fits. At about 110 tokens a second, 16,000 tokens
// stay inside timeoutMs.
let maxTokens = 16_000

let buildRequestBody = (
  ~model: string,
  ~imageBase64: string,
  ~structuredOutput: bool,
  ~mode: mode,
): JSON.t => {
  let webSearchType =
    Pricing.rowFor(model)->Option.map(r => r.webSearchToolType)->Option.getOr("web_search_20260209")
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
  let sizeText = (width: int, height: int): string =>
    "This photo is " ++
    Int.toString(width) ++
    " pixels wide and " ++
    Int.toString(height) ++ " pixels tall. Value the resellable items on this table."
  let text = switch mode {
  | Scene({width, height}) => sizeText(width, height)
  | Haul({width, height}) => sizeText(width, height)
  }
  let textBlock = Json.obj([("type", Json.str("text")), ("text", Json.str(text))])
  let tool = Json.obj([
    ("type", Json.str(webSearchType)),
    ("name", Json.str("web_search")),
    ("max_uses", Json.num(3.0)),
    ("blocked_domains", Json.arr([Json.str("ebay.com")])),
    // Search directly, never from a code step: parallel code steps stalled for about 96 s (docs/stall-fix.md).
    ("allowed_callers", Json.arr([Json.str("direct")])),
  ])
  let base = [
    ("model", Json.str(model)),
    ("max_tokens", Json.num(Int.toFloat(maxTokens))),
    ("system", Json.str(systemTextFor(mode))),
    (
      "messages",
      Json.arr([
        Json.obj([("role", Json.str("user")), ("content", Json.arr([imageBlock, textBlock]))]),
      ]),
    ),
    ("tools", Json.arr([tool])),
  ]
  let fields =
    structuredOutput
      ? Array.concat(base, [("output_config", Json.obj([("format", outputFormatFor(mode))]))])
      : base
  Json.obj(fields)
}

let messagesUrl = "https://api.anthropic.com/v1/messages"

// 10 real scenes on claude-sonnet-5 with web search (2026-09-24) took 11.9 s
// to 143.2 s in Claude, median 47.1 s. 180 s covers the slowest one. It
// stays under the 300 s headers timeout that Node's fetch (undici) applies
// on its own.
let timeoutMs = 180_000

let timeoutFor = (config: Config.t) => config.claudeTimeoutMs->Option.getOr(timeoutMs)

let postToClaude = async (~config: Config.t, apiKey: string, bodyJson: JSON.t) => {
  let headers = Dict.fromArray([
    ("content-type", "application/json"),
    ("x-api-key", apiKey),
    ("anthropic-version", "2023-06-01"),
  ])
  await Fetch.fetch(
    config.claudeUrl->Option.getOr(messagesUrl),
    ~init={
      Fetch.method: "POST",
      headers,
      body: JSON.stringify(bodyJson),
      signal: Fetch.AbortSignal.timeout(timeoutFor(config)),
    },
  )
}

// FIXTURES=1 forces fixture mode (reads tests/fixtures/claude-scene.json).
// Otherwise: no ANTHROPIC_API_KEY -> NoApiKey (the server turns this into a
// 503). On a 400 naming output_config, retry once without it, per CLAUDE.md
// rule: "nobody confirmed output_config works together with web search."
let send = async (
  ~config: Config.t,
  ~model: string,
  ~imageBase64: string,
  ~mode: mode,
): result<decoded, callError> =>
  if config.fixtures {
    let fixtureFile = switch mode {
    | Scene(_) => "claude-scene.json"
    | Haul(_) => "claude-haul.json"
    }
    let text = Node.Fs.readFileUtf8(Node.Path.join([config.fixturesDir, fixtureFile]), "utf8")
    parseClaudeJson(JSON.parseOrThrow(text))
  } else {
    switch config.anthropicApiKey {
    | None => Error(NoApiKey)
    | Some(apiKey) => {
        Console.log(
          "claude: requesting (structured output=" ++
          (config.structuredOutput ? "on" : "off") ++ ")",
        )
        let resp = await postToClaude(
          ~config,
          apiKey,
          buildRequestBody(~model, ~imageBase64, ~structuredOutput=config.structuredOutput, ~mode),
        )
        if Fetch.ok(resp) {
          parseClaudeJson(await Fetch.json(resp))
        } else if Fetch.status(resp) == 400 && config.structuredOutput {
          let errText = await Fetch.text(resp)
          if String.includes(errText, "output_config") {
            Console.log("claude: retrying without output_config after 400")
            let resp2 = await postToClaude(
              ~config,
              apiKey,
              buildRequestBody(~model, ~imageBase64, ~structuredOutput=false, ~mode),
            )
            if Fetch.ok(resp2) {
              parseClaudeJson(await Fetch.json(resp2))
            } else {
              Error(HttpError(Fetch.status(resp2), await Fetch.text(resp2)))
            }
          } else {
            Error(HttpError(400, errText))
          }
        } else {
          Error(HttpError(Fetch.status(resp), await Fetch.text(resp)))
        }
      }
    }
  }

// A scene that runs past the timeout makes fetch reject with a DOMException
// named TimeoutError. Return Timeout(ms) for it, so that the scene route
// answers 504 with a JSON error and not the generic 500.
let call = async (~config: Config.t, ~model: string, ~imageBase64: string, ~mode: mode): result<
  decoded,
  callError,
> =>
  try {
    await send(~config, ~model, ~imageBase64, ~mode)
  } catch {
  | JsExn(e) if JsExn.name(e) == Some("TimeoutError") => Error(Timeout(timeoutFor(config)))
  }
