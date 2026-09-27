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

// A well-formed box is 4 numbers; anything else (missing, wrong length, not
// numbers) decodes as None — a page with no box for an item shows "no box"
// rather than failing the whole item.
let decodeBox = (json: JSON.t): option<Types.box> =>
  switch JSON.Decode.array(json) {
  | Some(arr) if Array.length(arr) == 4 =>
    switch Array.filterMap(arr, JSON.Decode.float) {
    | [x1, y1, x2, y2] =>
      Some({Types.x1: Float.toInt(x1), y1: Float.toInt(y1), x2: Float.toInt(x2), y2: Float.toInt(y2)})
    | _ => None
    }
  | _ => None
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
    let box = Json.field(json, "box")->Option.flatMap(decodeBox)
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
      size: Json.stringField(json, "size")->Option.getOr(""),
      box,
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
    Json.intField(json, "imageWidth"),
    Json.intField(json, "imageHeight"),
    Json.field(json, "timing"),
    Json.field(json, "cost"),
  ) {
  | (
      Some(sceneId),
      Some(model),
      Some(fixture),
      Some(outputPath),
      Some(itemsJson),
      Some(imageWidth),
      Some(imageHeight),
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
        imageWidth,
        imageHeight,
        timing,
        cost,
        ebayNote: Json.stringField(json, "ebayNote"),
        quarterSeen: Json.boolField(json, "quarterSeen")->Option.getOr(false),
      })
    | (Error(e), _, _) | (_, Error(e), _) | (_, _, Error(e)) => Error(e)
    }
  | _ => Error("reply missing a required field")
  }

// -- haulStatus decode, field-for-field against Types.encodeHaulStatus -----
// (docs/spec-haul-mode.md "Step 3: brain queue" — the phone page decodes
// this same shape in step 5, so it lives here, not in a Node-only module.)

let decodeHaulGem = (json: JSON.t): result<Types.haulGem, string> =>
  switch (
    Json.stringField(json, "findId"),
    Json.stringField(json, "sceneId"),
    Json.stringField(json, "name"),
    Json.floatField(json, "estimateLowUsd"),
    Json.floatField(json, "estimateHighUsd"),
    Json.floatField(json, "confidence"),
    Json.stringField(json, "soldSearchUrl"),
  ) {
  | (
      Some(findId),
      Some(sceneId),
      Some(name),
      Some(estimateLowUsd),
      Some(estimateHighUsd),
      Some(confidence),
      Some(soldSearchUrl),
    ) =>
    let ebay = switch Json.field(json, "ebay") {
    | None => None
    | Some(v) =>
      switch decodeEbayStats(v) {
      | Ok(stats) => Some(stats)
      | Error(_) => None
      }
    }
    let box = Json.field(json, "box")->Option.flatMap(decodeBox)
    Ok({
      Types.findId,
      sceneId,
      name,
      where: Json.stringField(json, "where"),
      estimateLowUsd,
      estimateHighUsd,
      confidence,
      soldSearchUrl,
      ebay,
      box,
      imageWidth: Json.intField(json, "imageWidth"),
      imageHeight: Json.intField(json, "imageHeight"),
      size: Json.stringField(json, "size")->Option.getOr(""),
    })
  | _ => Error("gem missing a required field")
  }

let decodeFailedPhoto = (json: JSON.t): result<Types.failedPhoto, string> =>
  switch (Json.stringField(json, "sceneId"), Json.stringField(json, "error")) {
  | (Some(sceneId), Some(error)) => Ok({Types.sceneId, error})
  | _ => Error("failed photo missing a required field")
  }

let decodeHaulCounts = (json: JSON.t): result<Types.haulCounts, string> =>
  switch (
    Json.intField(json, "queued"),
    Json.intField(json, "running"),
    Json.intField(json, "valued"),
    Json.intField(json, "failed"),
  ) {
  | (Some(queued), Some(running), Some(valued), Some(failed)) =>
    Ok({Types.queued, running, valued, failed})
  | _ => Error("counts missing a required field")
  }

// A haul status round-trips its place through JSON: Types.encodePlace when
// present, JSON null when not (Types.res encodeHaulStatus). Absent key,
// present-but-null, and a malformed sub-object (missing lat/lon/source/at,
// or an unrecognized source) all decode as None the same way — Json.field
// already returns None for a missing key, and JSON.Decode.object rejects
// a JSON.Null value the same as any other non-object, so floatField/
// stringField on it fall through to None too.
let decodePlace = (placeJson: JSON.t): option<Types.place> =>
  switch (
    Json.floatField(placeJson, "lat"),
    Json.floatField(placeJson, "lon"),
    Json.stringField(placeJson, "source"),
    Json.stringField(placeJson, "at"),
  ) {
  | (Some(lat), Some(lon), Some(sourceStr), Some(at)) =>
    switch Place.sourceFromString(sourceStr) {
    | Some(source) =>
      Some({Types.lat, lon, accuracyM: Json.floatField(placeJson, "accuracyM"), source, at})
    | None => None
    }
  | _ => None
  }

let decodeHaulStatus = (json: JSON.t): result<Types.haulStatus, string> =>
  switch (
    Json.stringField(json, "haulId"),
    Json.stringField(json, "startedAt"),
    Json.floatField(json, "costUsd"),
    Json.floatField(json, "maxUsd"),
    Json.floatField(json, "gemMinUsd"),
    Json.field(json, "counts"),
    Json.arrayField(json, "gems"),
    Json.intField(json, "otherCount"),
    Json.arrayField(json, "failed"),
  ) {
  | (
      Some(haulId),
      Some(startedAt),
      Some(costUsd),
      Some(maxUsd),
      Some(gemMinUsd),
      Some(countsJson),
      Some(gemsJson),
      Some(otherCount),
      Some(failedJson),
    ) =>
    switch (
      decodeHaulCounts(countsJson),
      Array.map(gemsJson, decodeHaulGem)->Result.all,
      Array.map(failedJson, decodeFailedPhoto)->Result.all,
    ) {
    | (Ok(counts), Ok(gems), Ok(failed)) =>
      Ok({
        Types.haulId,
        name: Json.stringField(json, "name"),
        startedAt,
        doneAt: Json.stringField(json, "doneAt"),
        emailedAt: Json.stringField(json, "emailedAt"),
        costUsd,
        maxUsd,
        gemMinUsd,
        stopReason: Json.stringField(json, "stopReason"),
        emailNote: Json.stringField(json, "emailNote"),
        counts,
        gems,
        otherCount,
        failed,
        place: Json.field(json, "place")->Option.flatMap(decodePlace),
      })
    | (Error(e), _, _) | (_, Error(e), _) | (_, _, Error(e)) => Error(e)
    }
  | _ => Error("haul status missing a required field")
  }

let decodeHaulBuy = (json: JSON.t): result<Types.haulBuy, string> =>
  switch (Json.stringField(json, "name"), Json.floatField(json, "paidUsd")) {
  | (Some(name), Some(paidUsd)) =>
    Ok({
      Types.name,
      paidUsd,
      paidOn: Json.stringField(json, "paidOn"),
      soldUsd: Json.floatField(json, "soldUsd"),
      soldOn: Json.stringField(json, "soldOn"),
    })
  | _ => Error("buy missing a required field")
  }

let decodeHaulListRow = (json: JSON.t): result<Types.haulListRow, string> =>
  switch (
    Json.stringField(json, "haulId"),
    Json.stringField(json, "startedAt"),
    Json.intField(json, "photoCount"),
    Json.intField(json, "gemCount"),
    Json.floatField(json, "paidUsd"),
    Json.arrayField(json, "buys"),
  ) {
  | (
      Some(haulId),
      Some(startedAt),
      Some(photoCount),
      Some(gemCount),
      Some(paidUsd),
      Some(buysJson),
    ) =>
    switch Array.map(buysJson, decodeHaulBuy)->Result.all {
    | Ok(buys) =>
      Ok({
        Types.haulId,
        name: Json.stringField(json, "name"),
        startedAt,
        place: Json.field(json, "place")->Option.flatMap(decodePlace),
        photoCount,
        gemCount,
        paidUsd,
        buys,
      })
    | Error(e) => Error(e)
    }
  | _ => Error("haul list row missing a required field")
  }

let decodeHaulList = (json: JSON.t): result<array<Types.haulListRow>, string> =>
  switch JSON.Decode.array(json) {
  | Some(rowsJson) => Array.map(rowsJson, decodeHaulListRow)->Result.all
  | None => Error("haul list is not an array")
  }
