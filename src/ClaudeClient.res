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
  raw: JSON.t,
}

type callError = NoApiKey | HttpError(int, string) | DecodeFailed(decodeError)

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
    Ok({
      Types.name,
      maker,
      query,
      estimateLowUsd: low,
      estimateHighUsd: high,
      basis,
      confidence,
      sources,
    })
  | _ => Error("item missing a required field")
  }

let decodeItemsJson = (json: JSON.t): result<array<Types.claudeItem>, decodeError> =>
  switch Json.arrayField(json, "items") {
  | None => Error(SchemaMismatch("no items array"))
  | Some(arr) => Array.map(arr, decodeItem)->Result.all->Result.mapError(msg => SchemaMismatch(msg))
  }

// A decode failure is an error variant, never a crash: JSON.parseOrThrow's
// SyntaxError is caught with the `exception JsExn(_)` arm below, and every
// other branch is total over its input.
let decodeResponse = (responseJson: JSON.t): result<decoded, decodeError> => {
  let emptyUsage: Types.usage = {
    inputTokens: 0,
    outputTokens: 0,
    cacheReadInputTokens: 0,
    cacheCreationInputTokens: 0,
    webSearchRequests: 0,
  }
  let usage = Json.field(responseJson, "usage")->Option.map(decodeUsage)->Option.getOr(emptyUsage)
  switch Json.arrayField(responseJson, "content") {
  | None => Error(EmptyContent)
  | Some(blocks) =>
    switch extractJsonText(blocks) {
    | None => Error(EmptyContent)
    | Some(text) =>
      switch JSON.parseOrThrow(text) {
      | parsed => decodeItemsJson(parsed)->Result.map(items => {items, usage, raw: responseJson})
      | exception JsExn(_) =>
        switch Json.firstJsonObjectSpan(text) {
        | None => Error(NoJsonFound)
        | Some(span) =>
          switch JSON.parseOrThrow(span) {
          | parsed2 =>
            decodeItemsJson(parsed2)->Result.map(items => {items, usage, raw: responseJson})
          | exception JsExn(_) => Error(InvalidJson(text))
          }
        }
      }
    }
  }
}

let buildRequestBody = (~model: string, ~imageBase64: string, ~structuredOutput: bool): JSON.t => {
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
  let textBlock = Json.obj([
    ("type", Json.str("text")),
    ("text", Json.str("Value the resellable items on this table.")),
  ])
  let tool = Json.obj([
    ("type", Json.str(webSearchType)),
    ("name", Json.str("web_search")),
    ("max_uses", Json.num(3.0)),
    ("blocked_domains", Json.arr([Json.str("ebay.com")])),
  ])
  let base = [
    ("model", Json.str(model)),
    ("max_tokens", Json.num(8192.0)),
    ("system", Json.str(SystemPrompt.text)),
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
      ? Array.concat(base, [("output_config", Json.obj([("format", SystemPrompt.outputFormat)]))])
      : base
  Json.obj(fields)
}

let postToClaude = async (apiKey: string, bodyJson: JSON.t) => {
  let headers = Dict.fromArray([
    ("content-type", "application/json"),
    ("x-api-key", apiKey),
    ("anthropic-version", "2023-06-01"),
  ])
  await Fetch.fetch(
    "https://api.anthropic.com/v1/messages",
    ~init={
      Fetch.method: "POST",
      headers,
      body: JSON.stringify(bodyJson),
      signal: Fetch.AbortSignal.timeout(60_000),
    },
  )
}

// FIXTURES=1 forces fixture mode (reads tests/fixtures/claude-scene.json).
// Otherwise: no ANTHROPIC_API_KEY -> NoApiKey (the server turns this into a
// 503). On a 400 naming output_config, retry once without it, per CLAUDE.md
// rule: "nobody confirmed output_config works together with web search."
let call = async (~config: Config.t, ~model: string, ~imageBase64: string): result<decoded, callError> =>
  if config.fixtures {
    let text = Node.Fs.readFileUtf8(Node.Path.join([config.fixturesDir, "claude-scene.json"]), "utf8")
    switch decodeResponse(JSON.parseOrThrow(text)) {
    | Ok(d) => Ok(d)
    | Error(e) => Error(DecodeFailed(e))
    }
  } else {
    switch config.anthropicApiKey {
    | None => Error(NoApiKey)
    | Some(apiKey) => {
        Console.log(
          "claude: requesting (structured output=" ++
          (config.structuredOutput ? "on" : "off") ++ ")",
        )
        let resp = await postToClaude(
          apiKey,
          buildRequestBody(~model, ~imageBase64, ~structuredOutput=config.structuredOutput),
        )
        if Fetch.ok(resp) {
          switch decodeResponse(await Fetch.json(resp)) {
          | Ok(d) => Ok(d)
          | Error(e) => Error(DecodeFailed(e))
          }
        } else if Fetch.status(resp) == 400 && config.structuredOutput {
          let errText = await Fetch.text(resp)
          if String.includes(errText, "output_config") {
            Console.log("claude: retrying without output_config after 400")
            let resp2 = await postToClaude(
              apiKey,
              buildRequestBody(~model, ~imageBase64, ~structuredOutput=false),
            )
            if Fetch.ok(resp2) {
              switch decodeResponse(await Fetch.json(resp2)) {
              | Ok(d) => Ok(d)
              | Error(e) => Error(DecodeFailed(e))
              }
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
