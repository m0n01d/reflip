// SceneStream end to end: the synthetic fixture through Sse ->
// ClaudeEvents -> SceneStream, at 3 different chunkings of the raw SSE
// bytes. The log event order, the two search queries, the result
// count, the 3 decoded items and the final usage must not depend on
// chunking.

let fixturePath = Node.Path.join([Node.Process.cwd(), "tests/fixtures/claude-stream.sse"])
let sseText = Node.Fs.readFileUtf8(fixturePath, "utf8")

let scenePath = Node.Path.join([Node.Process.cwd(), "tests/fixtures/claude-scene.json"])
let sceneJson = JSON.parseOrThrow(Node.Fs.readFileUtf8(scenePath, "utf8"))
let expectedItems: array<Types.claudeItem> = switch ClaudeClient.decodeResponse(sceneJson) {
| Ok(decoded) => decoded.items
| Error(_) => []
}

let kindOf = (evt: SceneStream.logEvent): string =>
  switch evt {
  | SceneStream.ClaudeStarted(_) => "ClaudeStarted"
  | SceneStream.Thinking => "Thinking"
  | SceneStream.ToolRunStarted(_) => "ToolRunStarted"
  | SceneStream.ToolRunDone(_) => "ToolRunDone"
  | SceneStream.SearchStarted(_) => "SearchStarted"
  | SceneStream.SearchDone(_) => "SearchDone"
  | SceneStream.SearchFailed(_) => "SearchFailed"
  | SceneStream.BoxFound(_) => "BoxFound"
  | SceneStream.ItemFound(_) => "ItemFound"
  | SceneStream.ItemRejected(_) => "ItemRejected"
  | SceneStream.Finished(_) => "Finished"
  | SceneStream.StreamFailed(_) => "StreamFailed"
  }

// message_start; thinking; code_execution starts, then the nested
// web_search it calls starts and finishes (3 results), then the code
// run's own result; a second, plain web_search that fails; the 3 items;
// message_stop.
let expectedKinds = [
  "ClaudeStarted",
  "Thinking",
  "ToolRunStarted",
  "SearchStarted",
  "SearchDone",
  "ToolRunDone",
  "SearchStarted",
  "SearchFailed",
  "BoxFound",
  "ItemFound",
  "BoxFound",
  "ItemFound",
  "BoxFound",
  "ItemFound",
  "Finished",
]

let claudeItemsEqual = (a: Types.claudeItem, b: Types.claudeItem): bool =>
  a.name == b.name &&
  a.maker == b.maker &&
  a.query == b.query &&
  a.estimateLowUsd == b.estimateLowUsd &&
  a.estimateHighUsd == b.estimateHighUsd &&
  a.basis == b.basis &&
  a.confidence == b.confidence &&
  Array.join(a.sources, "|") == Array.join(b.sources, "|") &&
  a.size == b.size &&
  a.box == b.box

let itemArraysEqual = (a: array<Types.claudeItem>, b: array<Types.claudeItem>): bool =>
  if Array.length(a) != Array.length(b) {
    false
  } else {
    let ok = ref(true)
    for i in 0 to Array.length(a) - 1 {
      switch (Array.get(a, i), Array.get(b, i)) {
      | (Some(x), Some(y)) =>
          if !claudeItemsEqual(x, y) {
            ok := false
          }
      | _ => ok := false
      }
    }
    ok.contents
  }

let runFixtureAtChunkSize = (chunkSize: int): (SceneStream.model, array<SceneStream.logEvent>) => {
  let len = String.length(sseText)
  let rec go = (
    pos: int,
    sseState: Sse.t,
    model: SceneStream.model,
    acc: array<SceneStream.logEvent>,
  ): (SceneStream.model, array<SceneStream.logEvent>) =>
    if pos >= len {
      (model, acc)
    } else {
      let endPos = pos + chunkSize > len ? len : pos + chunkSize
      let chunk = String.substring(sseText, ~start=pos, ~end=endPos)
      let (newSseState, sseEvents) = Sse.feed(sseState, chunk)
      let (model2, acc2) = Array.reduce(sseEvents, (model, acc), ((m, a), evt) =>
        switch ClaudeEvents.decode(evt) {
        | Ok(decoded) =>
            let (m2, logs) = SceneStream.update(m, SceneStream.Event(decoded))
            (m2, Array.concat(a, logs))
        | Error(_) => (m, a)
        }
      )
      go(endPos, newSseState, model2, acc2)
    }
  go(0, Sse.empty, SceneStream.init, [])
}

let checkAtChunkSize = (chunkSize: int) => {
  let label = "chunk size " ++ Int.toString(chunkSize)
  let (model, logs) = runFixtureAtChunkSize(chunkSize)

  TestKit.check(label ++ ": log event count", Array.length(logs) == Array.length(expectedKinds))
  let kinds = Array.map(logs, kindOf)
  TestKit.check(label ++ ": log event order", Array.join(kinds, ",") == Array.join(expectedKinds, ","))

  switch Array.get(logs, 3) {
  | Some(SceneStream.SearchStarted({query})) =>
      TestKit.check(label ++ ": first search query", query == Some("vintage Pyrex nesting mixing bowls set"))
  | _ => TestKit.check(label ++ ": first search query present", false)
  }

  switch Array.get(logs, 4) {
  | Some(SceneStream.SearchDone({resultCount})) =>
      TestKit.check(label ++ ": search result count", resultCount == 3)
  | _ => TestKit.check(label ++ ": search result count present", false)
  }

  switch Array.get(logs, 6) {
  | Some(SceneStream.SearchStarted({query})) =>
      TestKit.check(
        label ++ ": second search query",
        query == Some("rare vintage board game lot price guide"),
      )
  | _ => TestKit.check(label ++ ": second search query present", false)
  }

  switch Array.get(logs, 7) {
  | Some(SceneStream.SearchFailed({errorCode})) =>
      TestKit.check(label ++ ": search failed code", errorCode == "max_uses_exceeded")
  | _ => TestKit.check(label ++ ": search failed code present", false)
  }

  switch Array.get(logs, 14) {
  | Some(SceneStream.Finished({stopReason, usage})) =>
      TestKit.check(label ++ ": finished stop reason", stopReason == "end_turn")
      TestKit.check(label ++ ": finished web search requests", usage.webSearchRequests == 2)
  | _ => TestKit.check(label ++ ": finished present", false)
  }

  let items = SceneStream.items(model)
  TestKit.check(label ++ ": 3 items in the model", Array.length(items) == 3)
  TestKit.check(
    label ++ ": items equal ClaudeClient.decodeResponse on claude-scene.json",
    itemArraysEqual(items, expectedItems),
  )
  TestKit.check(
    label ++ ": an item's size arrives from the stream",
    Array.get(items, 1)->Option.map(i => i.size) == Some("10 in"),
  )
  TestKit.check(
    label ++ ": quarterSeen arrives from the stream",
    SceneStream.quarterSeen(model) == true,
  )
}

let run = () => {
  TestKit.section("SceneStream (fixture end to end)")
  TestKit.check("claude-scene.json decodes 3 items for comparison", Array.length(expectedItems) == 3)

  let len = String.length(sseText)
  checkAtChunkSize(len)
  checkAtChunkSize(97)
  checkAtChunkSize(5)

  TestKit.section("SceneStream.quarterSeen (wrapped JSON fallback)")
  let wrapped = "Here is the result:\n{\"quarterSeen\": true, \"items\": []}\nEnd of output."
  let wrappedModel = {...SceneStream.init, text: wrapped}
  TestKit.check(
    "quarterSeen is true when the final text has prose around the JSON",
    SceneStream.quarterSeen(wrappedModel) == true,
  )
}
