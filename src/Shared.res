// Shared between the server (Server.res) and the browser page (src/web/):
// the model picker's ids and labels, and the decoder for the JSON that
// POST /api/scene replies with (mirrors Types.sceneReply / encodeSceneReply).
// No Node imports — this file compiles straight into the browser bundle too.
// Per reflip's CLAUDE.md: nothing else may hand-copy a model id string.

type model = Opus5_5 | Sonnet5 | Haiku4_5

let allModels = [Opus5_5, Sonnet5, Haiku4_5]

let defaultModel = Sonnet5

let modelId = (m: model): string =>
  switch m {
  | Opus5_5 => "claude-opus-5-5"
  | Sonnet5 => "claude-sonnet-5"
  | Haiku4_5 => "claude-haiku-4-5"
  }

let modelLabel = (m: model): string =>
  switch m {
  | Opus5_5 => "Opus 5.5"
  | Sonnet5 => "Sonnet 5 (the default)"
  | Haiku4_5 => "Haiku 4.5"
  }

let parseModelId = (id: string): option<model> => allModels->Array.find(m => modelId(m) == id)

// -- sceneReply decode, field-for-field against Types.encodeSceneReply -----

let decodeEbayStats = (json: JSON.t): result<Types.ebayStats, string> =>
  switch (
    Json.intField(json, "count"),
    Json.floatField(json, "minUsd"),
    Json.floatField(json, "p25Usd"),
    Json.floatField(json, "medianUsd"),
    Json.floatField(json, "p75Usd"),
    Json.floatField(json, "maxUsd"),
  ) {
  | (Some(count), Some(minUsd), Some(p25Usd), Some(medianUsd), Some(p75Usd), Some(maxUsd)) =>
    Ok({Types.count, minUsd, p25Usd, medianUsd, p75Usd, maxUsd})
  | _ => Error("ebay stats missing a required field")
  }

let decodeReplyItem = (json: JSON.t): result<Types.replyItem, string> =>
  switch (
    Json.stringField(json, "name"),
    Json.stringField(json, "query"),
    Json.floatField(json, "confidence"),
    Json.floatField(json, "estimateLowUsd"),
    Json.floatField(json, "estimateHighUsd"),
    Json.stringField(json, "basis"),
    Json.stringField(json, "soldSearchUrl"),
  ) {
  | (
      Some(name),
      Some(query),
      Some(confidence),
      Some(estimateLowUsd),
      Some(estimateHighUsd),
      Some(basis),
      Some(soldSearchUrl),
    ) =>
    let sources =
      Json.arrayField(json, "sources")
      ->Option.map(arr => Array.filterMap(arr, JSON.Decode.string))
      ->Option.getOr([])
    // `ebay` is `null` (not decodable as an object) whenever the server
    // skipped the lookup — that null just means "absent", not an error.
    let ebay = switch Json.field(json, "ebay") {
    | None => None
    | Some(v) =>
      switch decodeEbayStats(v) {
      | Ok(stats) => Some(stats)
      | Error(_) => None
      }
    }
    Ok({
      Types.name,
      query,
      confidence,
      estimateLowUsd,
      estimateHighUsd,
      basis,
      sources,
      ebay,
      soldSearchUrl,
    })
  | _ => Error("item missing a required field")
  }

let decodeTiming = (json: JSON.t): result<Types.timing, string> =>
  switch (
    Json.floatField(json, "serverMs"),
    Json.floatField(json, "claudeMs"),
    Json.floatField(json, "ebayMs"),
  ) {
  | (Some(serverMs), Some(claudeMs), Some(ebayMs)) => Ok({Types.serverMs, claudeMs, ebayMs})
  | _ => Error("timing missing a required field")
  }

let decodeCost = (json: JSON.t): result<Types.cost, string> =>
  switch (
    Json.floatField(json, "usd"),
    Json.intField(json, "inputTokens"),
    Json.intField(json, "outputTokens"),
    Json.intField(json, "cacheReadTokens"),
    Json.intField(json, "cacheWriteTokens"),
    Json.intField(json, "webSearches"),
  ) {
  | (
      Some(usd),
      Some(inputTokens),
      Some(outputTokens),
      Some(cacheReadTokens),
      Some(cacheWriteTokens),
      Some(webSearches),
    ) =>
    Ok({Types.usd, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, webSearches})
  | _ => Error("cost missing a required field")
  }

let decodeSceneReply = (json: JSON.t): result<Types.sceneReply, string> =>
  switch (
    Json.stringField(json, "sceneId"),
    Json.stringField(json, "model"),
    Json.boolField(json, "fixture"),
    Json.stringField(json, "outputPath"),
    Json.arrayField(json, "items"),
    Json.field(json, "timing"),
    Json.field(json, "cost"),
  ) {
  | (
      Some(sceneId),
      Some(model),
      Some(fixture),
      Some(outputPath),
      Some(itemsJson),
      Some(timingJson),
      Some(costJson),
    ) =>
    switch (
      Array.map(itemsJson, decodeReplyItem)->Result.all,
      decodeTiming(timingJson),
      decodeCost(costJson),
    ) {
    | (Ok(items), Ok(timing), Ok(cost)) =>
      Ok({
        Types.sceneId,
        model,
        fixture,
        outputPath,
        items,
        timing,
        cost,
        ebayNote: Json.stringField(json, "ebayNote"),
      })
    | (Error(e), _, _) | (_, Error(e), _) | (_, _, Error(e)) => Error(e)
    }
  | _ => Error("reply missing a required field")
  }
