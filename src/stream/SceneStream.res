// TEA core for turning a decoded Claude event stream into scene items
// and a log. Pure: no network, no timers. update() folds one
// ClaudeEvents.t into the model and returns the log lines it produced.

module D = JsonCombinators.Json.Decode

type item = {item: Types.claudeItem, box: option<array<int>>}

type logEvent =
  | ClaudeStarted({inputTokens: int})
  | Thinking
  | CodeRunStarted({id: string})
  | CodeRunDone({id: string, status: option<string>, returnCode: option<int>})
  | SearchStarted({id: string, query: option<string>})
  | SearchDone({id: string, resultCount: int})
  | SearchFailed({id: string, errorCode: string})
  | BoxFound({index: int, box: array<int>})
  | ItemFound({index: int, item: item})
  | ItemRejected({index: int, reason: string})
  | Finished({stopReason: string, usage: Types.usage})
  | StreamFailed(string)

// What a still-open content block was, so a later delta or block-stop
// event (which only carries the block's index) knows how to react.
// WebSearchBlock's accumulator is a ref so an input_json_delta chunk can
// append in place without rebuilding openBlocks on every delta.
type openBlock =
  | TextBlock
  | CodeExecBlock(string)
  | WebSearchBlock({id: string, queryEmittedAtStart: bool, partialInput: ref<string>})

type model = {
  items: array<item>,
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
    }
  })

  let query: D.t<option<string>> = D.object(field => field.optional("query", D.string))
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

let items = (model: model): array<item> => model.items
let usage = (model: model): Types.usage => model.usage
let finalText = (model: model): string => model.text

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
          let (box, model2) = takeBoxFor(model, index)
          let it = {item: claudeItem, box}
          ({...model2, items: Array.concat(model2.items, [it])}, [ItemFound({index, item: it})])
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
              | "code_execution" => (registerOpenBlock(resetModel, index, CodeExecBlock(id)), [])
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
              | _ => (resetModel, [])
              }
          | ClaudeEvents.WebSearchResult({toolUseId, outcome}) =>
              switch outcome {
              | ClaudeEvents.Results(n) => (model, [SearchDone({id: toolUseId, resultCount: n})])
              | ClaudeEvents.SearchError(code) => (
                  model,
                  [SearchFailed({id: toolUseId, errorCode: code})],
                )
              }
          | ClaudeEvents.CodeExecutionResult({toolUseId, run}) => (
              model,
              [CodeRunDone({id: toolUseId, status: run.status, returnCode: run.returnCode})],
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
          | Some(CodeExecBlock(_)) | None => (model, [])
          }

      | ClaudeEvents.BlockStop({index}) =>
          switch findOpenBlock(model.openBlocks, index) {
          | Some(CodeExecBlock(id)) => (model, [CodeRunStarted({id: id})])
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
