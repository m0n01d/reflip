// TEA core for turning a decoded Claude event stream into scene items
// and a log. Pure: no network, no timers. update() folds one
// ClaudeEvents.t into the model and returns the log lines it produced.

module D = JsonCombinators.Json.Decode

type logEvent =
  | ClaudeStarted({inputTokens: int})
  | Thinking
  | ToolRunStarted({id: string, name: string})
  | ToolRunDone({id: string, name: string, status: option<string>, returnCode: option<int>})
  | SearchStarted({id: string, query: option<string>})
  | SearchDone({id: string, resultCount: int})
  | SearchFailed({id: string, errorCode: string})
  | BoxFound({index: int, box: array<int>})
  | ItemFound({index: int, item: Types.claudeItem})
  | ItemRejected({index: int, reason: string})
  | Finished({stopReason: string, usage: Types.usage})
  | StreamFailed(string)

// What a still-open content block was, so a later delta or block-stop
// event (which only carries the block's index) knows how to react.
// WebSearchBlock's accumulator is a ref so an input_json_delta chunk can
// append in place without rebuilding openBlocks on every delta.
type openBlock =
  | TextBlock
  | ToolUseBlock({id: string, name: string})
  | WebSearchBlock({id: string, queryEmittedAtStart: bool, partialInput: ref<string>})

type model = {
  items: array<Types.claudeItem>,
  usage: Types.usage,
  lastStopReason: option<string>,
  scanner: ItemScanner.t,
  text: string,
  pendingBox: option<(int, array<int>)>,
  openBlocks: array<(int, openBlock)>,
}

type msg = Event(ClaudeEvents.t)

module ItemDecode = {
  let claudeItem: D.t<Types.claudeItem> = D.object(field => {
      let maker = field.optional("maker", D.string)->Option.flatMap(m => m == "" ? None : Some(m))
      let sources = field.optional("sources", D.array(D.string))->Option.getOr([])
      {
        Types.name: field.required("name", D.string),
        maker,
        query: field.required("query", D.string),
        estimateLowUsd: field.required("estimateLowUsd", D.float),
        estimateHighUsd: field.required("estimateHighUsd", D.float),
        basis: field.required("basis", D.string),
        confidence: field.required("confidence", D.float),
        sources,
        where: field.optional("where", D.string),
        size: field.optional("size", D.string)->Option.getOr(""),
        box: field.optional("box", D.array(D.float)),
      }
    })

  let query: D.t<option<string>> = D.object(field => field.optional("query", D.string))

  let quarterSeen: D.t<bool> = D.object(field =>
    field.optional("quarterSeen", D.bool)->Option.getOr(false)
  )
}

let extractQueryFromJson = (json: JSON.t): option<string> =>
  switch JsonCombinators.Json.decode(json, ItemDecode.query) {
  | Ok(q) => q
  | Error(_) => None
  }

let extractQueryFromText = (text: string): option<string> =>
  switch JsonCombinators.Json.parse(text) {
  | Ok(json) => extractQueryFromJson(json)
  | Error(_) => None
  }

let emptyUsage: Types.usage = {
  Types.inputTokens: 0,
  outputTokens: 0,
  cacheReadInputTokens: 0,
  cacheCreationInputTokens: 0,
  webSearchRequests: 0,
}

let init: model = {
  items: [],
  usage: emptyUsage,
  lastStopReason: None,
  scanner: ItemScanner.empty,
  text: "",
  pendingBox: None,
  openBlocks: [],
}

let items = (model: model): array<Types.claudeItem> => model.items
let usage = (model: model): Types.usage => model.usage
let finalText = (model: model): string => model.text

// The full structured-output JSON is the text of the last (uninterrupted)
// text block — see docs/stream-spike.md §2: with search on, Claude writes
// no JSON until its last code step ends, so no later tool call resets
// model.text out from under it. Defaults to false on a parse miss, same
// posture as extractQueryFromText.
let quarterSeen = (model: model): bool =>
  switch JsonCombinators.Json.parse(model.text) {
  | Ok(json) =>
      switch JsonCombinators.Json.decode(json, ItemDecode.quarterSeen) {
      | Ok(qs) => qs
      | Error(_) => false
      }
  | Error(_) => false
  }

let findOpenBlock = (openBlocks: array<(int, openBlock)>, index: int): option<openBlock> =>
  Array.find(openBlocks, ((i, _)) => i == index)->Option.map(((_, b)) => b)

let registerOpenBlock = (model: model, index: int, block: openBlock): model => {
  ...model,
  openBlocks: Array.concat(model.openBlocks, [(index, block)]),
}

// The box the ItemScanner just closed for this same item index, if any.
// BoxClosed always arrives before its item's ItemClosed.
let takeBoxFor = (model: model, index: int): (option<array<int>>, model) =>
  switch model.pendingBox {
  | Some((bi, box)) if bi == index => (Some(box), {...model, pendingBox: None})
  | Some(_) => (None, {...model, pendingBox: None})
  | None => (None, model)
  }

let applyFound = (model: model, found: ItemScanner.found): (model, array<logEvent>) =>
  switch found {
  | ItemScanner.BoxClosed({index, box}) => (
      {...model, pendingBox: Some((index, box))},
      [BoxFound({index, box})],
    )
  | ItemScanner.ItemClosed({index, json}) =>
      switch JsonCombinators.Json.decode(json, ItemDecode.claudeItem) {
      | Ok(claudeItem) =>
          let (_, model2) = takeBoxFor(model, index)
          (
            {...model2, items: Array.concat(model2.items, [claudeItem])},
            [ItemFound({index, item: claudeItem})],
          )
      | Error(msg) =>
          let (_, model2) = takeBoxFor(model, index)
          (model2, [ItemRejected({index, reason: msg})])
      }
  | ItemScanner.ItemUnparsable({index, text}) => (
      model,
      [ItemRejected({index, reason: "unparsable JSON: " ++ text})],
    )
  }

let applyFoundAll = (model: model, found: array<ItemScanner.found>): (model, array<logEvent>) =>
  Array.reduce(found, (model, []), ((m, acc), f) => {
    let (m2, evts) = applyFound(m, f)
    (m2, Array.concat(acc, evts))
  })

let update = (model: model, msg: msg): (model, array<logEvent>) =>
  switch msg {
  | Event(evt) =>
      switch evt {
      | ClaudeEvents.MessageStart({usage: startUsage}) => (
          {...model, usage: startUsage},
          [ClaudeStarted({inputTokens: startUsage.inputTokens})],
        )

      | ClaudeEvents.BlockStart({index, block}) =>
          switch block {
          | ClaudeEvents.TextStart => (registerOpenBlock(model, index, TextBlock), [])
          | ClaudeEvents.ThinkingStart => (model, [Thinking])
          | ClaudeEvents.ServerToolUseStart({id, name, input}) =>
              let resetModel = {...model, scanner: ItemScanner.empty, text: ""}
              switch name {
              | "web_search" =>
                  switch input->Option.flatMap(extractQueryFromJson) {
                  | Some(q) => (
                      registerOpenBlock(
                        resetModel,
                        index,
                        WebSearchBlock({id, queryEmittedAtStart: true, partialInput: ref("")}),
                      ),
                      [SearchStarted({id, query: Some(q)})],
                    )
                  | None => (
                      registerOpenBlock(
                        resetModel,
                        index,
                        WebSearchBlock({id, queryEmittedAtStart: false, partialInput: ref("")}),
                      ),
                      [],
                    )
                  }
              // Any other server tool (code_execution, text_editor_code_execution,
              // and whatever Anthropic ships next) starts here and is reported at
              // its BlockStop, once we know it actually ran.
              | _ => (registerOpenBlock(resetModel, index, ToolUseBlock({id, name})), [])
              }
          | ClaudeEvents.WebSearchResult({toolUseId, outcome}) =>
              switch outcome {
              | ClaudeEvents.Results(n) => (model, [SearchDone({id: toolUseId, resultCount: n})])
              | ClaudeEvents.SearchError(code) => (
                  model,
                  [SearchFailed({id: toolUseId, errorCode: code})],
                )
              }
          | ClaudeEvents.ToolResult({toolUseId, run}) =>
              // The matching ServerToolUseStart carried the name; a *_tool_result
              // block only carries the id, so look it up in the still-open blocks.
              let name =
                Array.find(model.openBlocks, ((_, b)) =>
                  switch b {
                  | ToolUseBlock({id}) => id == toolUseId
                  | _ => false
                  }
                )
                ->Option.flatMap(((_, b)) =>
                  switch b {
                  | ToolUseBlock({name}) => Some(name)
                  | _ => None
                  }
                )
                ->Option.getOr("tool")
              (
                model,
                [ToolRunDone({id: toolUseId, name, status: run.status, returnCode: run.returnCode})],
              )
          | ClaudeEvents.OtherBlock(_) => (model, [])
          }

      | ClaudeEvents.BlockDelta({index, delta}) =>
          switch findOpenBlock(model.openBlocks, index) {
          | Some(TextBlock) =>
              switch delta {
              | ClaudeEvents.TextDelta(text) =>
                  let (scanner2, found) = ItemScanner.feed(model.scanner, text)
                  let model2 = {...model, scanner: scanner2, text: model.text ++ text}
                  applyFoundAll(model2, found)
              | _ => (model, [])
              }
          | Some(WebSearchBlock({partialInput})) =>
              switch delta {
              | ClaudeEvents.InputJsonDelta(chunk) =>
                  partialInput := partialInput.contents ++ chunk
                  (model, [])
              | _ => (model, [])
              }
          | Some(ToolUseBlock(_)) | None => (model, [])
          }

      | ClaudeEvents.BlockStop({index}) =>
          switch findOpenBlock(model.openBlocks, index) {
          | Some(ToolUseBlock({id, name})) => (model, [ToolRunStarted({id, name})])
          | Some(WebSearchBlock({queryEmittedAtStart: true})) => (model, [])
          | Some(WebSearchBlock({id, queryEmittedAtStart: false, partialInput})) => (
              model,
              [SearchStarted({id, query: extractQueryFromText(partialInput.contents)})],
            )
          | Some(TextBlock) | None => (model, [])
          }

      | ClaudeEvents.MessageDelta({stopReason, usage: deltaUsage}) => (
          {...model, usage: deltaUsage, lastStopReason: stopReason},
          [],
        )

      | ClaudeEvents.MessageStop => (
          model,
          [Finished({stopReason: model.lastStopReason->Option.getOr("unknown"), usage: model.usage})],
        )

      | ClaudeEvents.Ping => (model, [])

      | ClaudeEvents.ApiError({errorType, message}) => (
          model,
          [StreamFailed(errorType ++ ": " ++ message)],
        )

      | ClaudeEvents.Unknown(_) => (model, [])
      }
  }
