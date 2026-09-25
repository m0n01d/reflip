// `npm run spike:stream` — the measurement runner for the stream spike.
//
// It answers: on a real photo, streamed through ClaudeStream.run, when do
// the first box and the first item arrive, against the total time? It
// compares box-last (main's structured-output schema as it stands, box at
// the end of "properties") with box-second (box moved right after "name"),
// and a pass with the web_search tool removed.
//
// No network calls happen unless the caller supplies a real
// ANTHROPIC_API_KEY and does not set FIXTURES=1. With FIXTURES=1,
// ClaudeStream.run replays tests/fixtures/claude-stream.sse instead.
//
// Every raw SSE event is appended to data/spike/<label>.events.jsonl as it
// arrives, one JSON object per line: {ms, event, data}. One summary line is
// appended to data/spike/runs.jsonl per run. Nothing here ever prints the
// API key or a request header.

type schemaArg = BoxLast | BoxSecond
type searchArg = SearchOn | SearchOff

type args = {
  photo: string,
  label: string,
  schema: schemaArg,
  search: searchArg,
  model: string,
  stopAfterFirstItem: bool,
  promptOnestep: bool,
  searchTool: option<string>,
  directSearch: bool,
  dynamicFiltering: bool,
  noParallel: bool,
  printBody: bool,
}

let defaultArgs: args = {
  photo: "",
  label: "",
  schema: BoxSecond,
  search: SearchOn,
  model: Pricing.defaultModel,
  stopAfterFirstItem: false,
  promptOnestep: false,
  searchTool: None,
  directSearch: false,
  dynamicFiltering: false,
  noParallel: false,
  printBody: false,
}

let usageText = "usage: spike:stream --photo PATH --label NAME [--schema box-last|box-second] [--search on|off] [--model ID] [--stop-after-first-item] [--prompt-onestep] [--search-tool TYPE] [--direct-search] [--dynamic-filtering] [--no-parallel] [--print-body]"

// Pure: walks argv from `i` on, folding flags into `acc`. Node.Process.argv
// is ["node", "<script>.mjs", ...actual args], so callers start at i=2.
let rec parseFrom = (argv: array<string>, i: int, acc: args): result<args, string> =>
  if i >= Array.length(argv) {
    Ok(acc)
  } else {
    switch Array.getUnsafe(argv, i) {
    | "--photo" =>
      switch Array.get(argv, i + 1) {
      | Some(v) => parseFrom(argv, i + 2, {...acc, photo: v})
      | None => Error("--photo needs a value")
      }
    | "--label" =>
      switch Array.get(argv, i + 1) {
      | Some(v) => parseFrom(argv, i + 2, {...acc, label: v})
      | None => Error("--label needs a value")
      }
    | "--schema" =>
      switch Array.get(argv, i + 1) {
      | Some("box-last") => parseFrom(argv, i + 2, {...acc, schema: BoxLast})
      | Some("box-second") => parseFrom(argv, i + 2, {...acc, schema: BoxSecond})
      | Some(v) => Error("unknown --schema value: " ++ v)
      | None => Error("--schema needs a value")
      }
    | "--search" =>
      switch Array.get(argv, i + 1) {
      | Some("on") => parseFrom(argv, i + 2, {...acc, search: SearchOn})
      | Some("off") => parseFrom(argv, i + 2, {...acc, search: SearchOff})
      | Some(v) => Error("unknown --search value: " ++ v)
      | None => Error("--search needs a value")
      }
    | "--model" =>
      switch Array.get(argv, i + 1) {
      | Some(v) => parseFrom(argv, i + 2, {...acc, model: v})
      | None => Error("--model needs a value")
      }
    | "--stop-after-first-item" => parseFrom(argv, i + 1, {...acc, stopAfterFirstItem: true})
    | "--prompt-onestep" => parseFrom(argv, i + 1, {...acc, promptOnestep: true})
    | "--search-tool" =>
      switch Array.get(argv, i + 1) {
      | Some(v) => parseFrom(argv, i + 2, {...acc, searchTool: Some(v)})
      | None => Error("--search-tool needs a value")
      }
    | "--direct-search" => parseFrom(argv, i + 1, {...acc, directSearch: true})
    | "--dynamic-filtering" => parseFrom(argv, i + 1, {...acc, dynamicFiltering: true})
    | "--no-parallel" => parseFrom(argv, i + 1, {...acc, noParallel: true})
    | "--print-body" => parseFrom(argv, i + 1, {...acc, printBody: true})
    | other => Error("unknown argument: " ++ other)
    }
  }

// Pure: replaces the JSON value at `path` inside `json` with `f(value)`.
// A missing key anywhere on the path leaves `json` untouched. Every
// ancestor dict is copied (Dict.fromArray(Dict.toArray(_))), never
// mutated, so this can never corrupt a shared schema constant.
let rec updateField = (json: JSON.t, path: list<string>, f: JSON.t => JSON.t): JSON.t =>
  switch path {
  | list{} => f(json)
  | list{key, ...rest} =>
    switch JSON.Decode.object(json) {
    | None => json
    | Some(d) =>
      switch Dict.get(d, key) {
      | None => json
      | Some(child) =>
        let d2 = Dict.fromArray(Dict.toArray(d))
        Dict.set(d2, key, updateField(child, rest, f))
        JSON.Encode.object(d2)
      }
    }
  }

// Pure: box-second. Moves "box" to right after "name" in an item schema's
// "properties" object. Everything else — type, required,
// additionalProperties, every other property — is untouched.
let moveBoxAfterName = (itemSchema: JSON.t): JSON.t =>
  switch JSON.Decode.object(itemSchema) {
  | None => itemSchema
  | Some(schemaDict) =>
    switch Dict.get(schemaDict, "properties")->Option.flatMap(JSON.Decode.object) {
    | None => itemSchema
    | Some(propsDict) =>
      switch Dict.get(propsDict, "box") {
      | None => itemSchema
      | Some(boxValue) =>
        let reordered: array<(string, JSON.t)> = Array.reduce(
          Dict.toArray(propsDict),
          [],
          (acc, (k, v)) =>
            if k == "box" {
              acc
            } else if k == "name" {
              Array.concat(acc, [(k, v), ("box", boxValue)])
            } else {
              Array.concat(acc, [(k, v)])
            },
        )
        let schemaDict2 = Dict.fromArray(Dict.toArray(schemaDict))
        Dict.set(schemaDict2, "properties", JSON.Encode.object(Dict.fromArray(reordered)))
        JSON.Encode.object(schemaDict2)
      }
    }
  }

// Where the scene item schema sits inside a structured-output request body
// built by ClaudeClient.buildRequestBody. See SystemPrompt.res:
// outputFormat -> responseSchema -> properties.items -> {type, items: itemSchema}.
let itemSchemaPath = list{"output_config", "format", "schema", "properties", "items", "items"}

let applySchema = (schema: schemaArg, body: JSON.t): JSON.t =>
  switch schema {
  | BoxLast =>
    updateField(body, itemSchemaPath, itemSchema =>
      switch JSON.Decode.object(itemSchema) {
      | None => itemSchema
      | Some(schemaDict) =>
        switch Dict.get(schemaDict, "properties")->Option.flatMap(JSON.Decode.object) {
        | None => itemSchema
        | Some(propsDict) =>
          switch Dict.get(propsDict, "box") {
          | None => itemSchema
          | Some(boxValue) =>
            let withoutBox = Array.filter(Dict.toArray(propsDict), ((k, _)) => k != "box")
            let reordered = Array.concat(withoutBox, [("box", boxValue)])
            let schemaDict2 = Dict.fromArray(Dict.toArray(schemaDict))
            Dict.set(schemaDict2, "properties", JSON.Encode.object(Dict.fromArray(reordered)))
            JSON.Encode.object(schemaDict2)
          }
        }
      }
    )
  | BoxSecond => updateField(body, itemSchemaPath, moveBoxAfterName)
  }

let removeTools = (body: JSON.t): JSON.t =>
  switch JSON.Decode.object(body) {
  | None => body
  | Some(d) => JSON.Encode.object(Dict.fromArray(Array.filter(Dict.toArray(d), ((k, _)) => k != "tools")))
  }

let applySearch = (search: searchArg, body: JSON.t): JSON.t =>
  switch search {
  | SearchOn => body
  | SearchOff => removeTools(body)
  }

// Pure: does this raw SSE event carry a content_block_delta/text_delta?
// Reuses ClaudeEvents.decode (the module's own public decoder) rather than
// re-parsing event.data by hand.
let isTextDelta = (sseEvt: Sse.event): bool =>
  switch ClaudeEvents.decode(sseEvt) {
  | Ok(ClaudeEvents.BlockDelta({delta: ClaudeEvents.TextDelta(_)})) => true
  | _ => false
  }

let claudeItemEqual = (a: Types.claudeItem, b: Types.claudeItem): bool =>
  a.name == b.name &&
  a.maker == b.maker &&
  a.query == b.query &&
  a.estimateLowUsd == b.estimateLowUsd &&
  a.estimateHighUsd == b.estimateHighUsd &&
  a.basis == b.basis &&
  a.confidence == b.confidence &&
  a.sources == b.sources &&
  a.where == b.where &&
  a.box == b.box

let claudeItemsEqual = (a: array<Types.claudeItem>, b: array<Types.claudeItem>): bool =>
  Array.length(a) == Array.length(b) &&
  Array.reduceWithIndex(a, true, (acc, itemA, i) =>
    acc && Array.get(b, i)->Option.map(itemB => claudeItemEqual(itemA, itemB))->Option.getOr(false)
  )

let fmtMs = (m: option<float>): string =>
  switch m {
  | None => "-"
  | Some(v) => Float.toFixed(v, ~digits=0) ++ "ms"
  }

let fmtOptInt = (o: option<int>): string =>
  switch o {
  | None => "-"
  | Some(v) => Int.toString(v)
  }

let eventLine = (ms: float, sseEvt: Sse.event): string =>
  JSON.stringify(
    Json.obj([("ms", Json.num(ms)), ("event", Json.str(sseEvt.event)), ("data", Json.str(sseEvt.data))]),
  )

let schemaLabel = (s: schemaArg): string =>
  switch s {
  | BoxLast => "box-last"
  | BoxSecond => "box-second"
  }

let searchLabel = (s: searchArg): string =>
  switch s {
  | SearchOn => "on"
  | SearchOff => "off"
  }

let encodeOptMs = (m: option<float>): JSON.t =>
  switch m {
  | None => JSON.Encode.null
  | Some(v) => Json.num(v)
  }

let encodeOptInt = (o: option<int>): JSON.t =>
  switch o {
  | None => JSON.Encode.null
  | Some(v) => Json.num(Int.toFloat(v))
  }

let encodeUsage = (u: Types.usage): JSON.t =>
  Json.obj([
    ("inputTokens", Json.num(Int.toFloat(u.inputTokens))),
    ("outputTokens", Json.num(Int.toFloat(u.outputTokens))),
    ("cacheReadInputTokens", Json.num(Int.toFloat(u.cacheReadInputTokens))),
    ("cacheCreationInputTokens", Json.num(Int.toFloat(u.cacheCreationInputTokens))),
    ("webSearchRequests", Json.num(Int.toFloat(u.webSearchRequests))),
  ])

type summary = {
  label: string,
  photo: string,
  width: int,
  height: int,
  model: string,
  schema: schemaArg,
  search: searchArg,
  headersMs: option<float>,
  messageStartMs: option<float>,
  inputTokensAtStart: option<int>,
  toolLines: array<string>,
  searchLines: array<string>,
  firstTextDeltaMs: option<float>,
  firstBoxMs: option<float>,
  firstItemMs: option<float>,
  lastItemMs: option<float>,
  doneMs: option<float>,
  itemCount: int,
  usage: Types.usage,
  usd: float,
  stopReason: string,
  streamFailed: option<string>,
  itemsEqualFinalDecode: bool,
  outcomeTag: string,
  stopAfterFirstItem: bool,
  stopFiredMs: option<float>,
  stopToEndMs: option<float>,
  promptOnestep: bool,
  webSearchToolType: option<string>,
  callers: string,
  noParallel: bool,
  codeStepCount: int,
  codeStepTimeouts: int,
  codeStepLongestMs: option<float>,
}

// Pure: the console report, under 40 lines for a normal run (a handful of
// tool/search lines plus a fixed 14-line core, plus one optional
// stream-failed line and one optional stop-to-end line).
let summaryLines = (s: summary): array<string> => {
  let core1 = [
    "photo: " ++ s.photo ++ " (" ++ Int.toString(s.width) ++ "x" ++ Int.toString(s.height) ++ ")",
    "model: " ++ s.model ++ "  schema: " ++ schemaLabel(s.schema) ++ "  search: " ++ searchLabel(s.search),
    "variant: prompt=" ++
    (s.promptOnestep ? "onestep" : "default") ++
    " tool=" ++
    s.webSearchToolType->Option.getOr("none") ++
    " callers=" ++
    s.callers ++
    " parallel=" ++
    (s.noParallel ? "off" : "default"),
    "headers: " ++ fmtMs(s.headersMs),
    "message_start: " ++ fmtMs(s.messageStartMs) ++ "  input_tokens=" ++ fmtOptInt(s.inputTokensAtStart),
  ]
  let withTools = Array.concat(core1, s.toolLines)
  let withSearches = Array.concat(withTools, s.searchLines)
  let withCodeSteps = Array.concat(
    withSearches,
    [
      "code steps: " ++
      Int.toString(s.codeStepCount) ++
      "  detection_timeout: " ++
      Int.toString(s.codeStepTimeouts) ++
      "  longest step: " ++
      fmtMs(s.codeStepLongestMs),
    ],
  )
  let core2 = [
    "first text delta: " ++ fmtMs(s.firstTextDeltaMs),
    "first box: " ++ fmtMs(s.firstBoxMs),
    "first item: " ++ fmtMs(s.firstItemMs),
    "last item: " ++ fmtMs(s.lastItemMs),
    "done: " ++ fmtMs(s.doneMs),
    "items: " ++ Int.toString(s.itemCount),
    "usage: in=" ++
    Int.toString(s.usage.inputTokens) ++
    " out=" ++
    Int.toString(s.usage.outputTokens) ++
    " cacheRead=" ++
    Int.toString(s.usage.cacheReadInputTokens) ++
    " cacheWrite=" ++
    Int.toString(s.usage.cacheCreationInputTokens) ++
    " webSearch=" ++
    Int.toString(s.usage.webSearchRequests),
    "usd: $" ++ Float.toFixed(s.usd, ~digits=4),
    "stop reason: " ++ s.stopReason,
    "items equal final decode: " ++ (s.itemsEqualFinalDecode ? "true" : "false"),
    "outcome: " ++ s.outcomeTag,
  ]
  let withCore2 = Array.concat(withCodeSteps, core2)
  let withFailed = switch s.streamFailed {
  | None => withCore2
  | Some(msg) => Array.concat(withCore2, ["stream failed: " ++ msg])
  }
  s.stopAfterFirstItem
    ? Array.concat(
        withFailed,
        ["stop to end: " ++ fmtMs(s.stopToEndMs) ++ "  items kept: " ++ Int.toString(s.itemCount)],
      )
    : withFailed
}

let summaryJson = (s: summary): JSON.t =>
  Json.obj([
    ("label", Json.str(s.label)),
    ("photo", Json.str(s.photo)),
    ("width", Json.num(Int.toFloat(s.width))),
    ("height", Json.num(Int.toFloat(s.height))),
    ("model", Json.str(s.model)),
    ("schema", Json.str(schemaLabel(s.schema))),
    ("search", Json.str(searchLabel(s.search))),
    ("headersMs", encodeOptMs(s.headersMs)),
    ("messageStartMs", encodeOptMs(s.messageStartMs)),
    ("inputTokensAtStart", encodeOptInt(s.inputTokensAtStart)),
    ("firstTextDeltaMs", encodeOptMs(s.firstTextDeltaMs)),
    ("firstBoxMs", encodeOptMs(s.firstBoxMs)),
    ("firstItemMs", encodeOptMs(s.firstItemMs)),
    ("lastItemMs", encodeOptMs(s.lastItemMs)),
    ("doneMs", encodeOptMs(s.doneMs)),
    ("itemCount", Json.num(Int.toFloat(s.itemCount))),
    ("usage", encodeUsage(s.usage)),
    ("usd", Json.num(s.usd)),
    ("stopReason", Json.str(s.stopReason)),
    ("streamFailed", switch s.streamFailed {
      | None => JSON.Encode.null
      | Some(m) => Json.str(m)
      }),
    ("itemsEqualFinalDecode", Json.boolJ(s.itemsEqualFinalDecode)),
    ("outcome", Json.str(s.outcomeTag)),
    ("stopAfterFirstItem", Json.boolJ(s.stopAfterFirstItem)),
    ("stopFiredMs", encodeOptMs(s.stopFiredMs)),
    ("stopToEndMs", encodeOptMs(s.stopToEndMs)),
    (
      "variant",
      Json.obj([
        ("prompt", Json.str(s.promptOnestep ? "onestep" : "default")),
        ("tool", Json.str(s.webSearchToolType->Option.getOr("none"))),
        ("callers", Json.str(s.callers)),
        ("parallel", Json.str(s.noParallel ? "off" : "default")),
      ]),
    ),
    ("codeStepCount", Json.num(Int.toFloat(s.codeStepCount))),
    ("codeStepTimeouts", Json.num(Int.toFloat(s.codeStepTimeouts))),
    ("codeStepLongestMs", encodeOptMs(s.codeStepLongestMs)),
  ])

// The effect edge: builds the request, drives ClaudeStream.run, and
// reports. Config.fromEnv() and the AbortController it owns live here;
// every transformation above is a pure helper.
let runSpike = async (~args: args, ~buf: Node.Buffer.t, ~width: int, ~height: int): unit => {
  let config = Config.fromEnv()
  let imageBase64 = Node.Buffer.toStringWithEncoding(buf, "base64")

  // -- Stall-fix variants (docs/stream-spike.md "Recommendation" 3) ---------
  // Each helper is a no-op JSON.t => JSON.t transform, applied in buildBody
  // after applySearch. They only touch the keys the flag names; every other
  // key on the body and on the web_search tool (blocked_domains, max_uses)
  // passes through untouched.

  let onestepParagraph = "If you search, make all of your web searches from one code execution step. Never start a second code execution step while one is running."

  let applyPromptOnestep = (enabled: bool, body: JSON.t): JSON.t =>
    if !enabled {
      body
    } else {
      switch JSON.Decode.object(body) {
      | None => body
      | Some(d) =>
        switch Dict.get(d, "system")->Option.flatMap(JSON.Decode.string) {
        | None => body
        | Some(sys) => {
            let d2 = Dict.fromArray(Dict.toArray(d))
            Dict.set(d2, "system", Json.str(sys ++ "\n\n" ++ onestepParagraph))
            JSON.Encode.object(d2)
          }
        }
      }
    }

  // Applies `f` to the `tools[]` entry whose "name" is "web_search". A no-op
  // when "tools" is absent (--search off already removed it).
  let mapWebSearchTool = (body: JSON.t, f: JSON.t => JSON.t): JSON.t =>
    switch JSON.Decode.object(body) {
    | None => body
    | Some(d) =>
      switch Dict.get(d, "tools")->Option.flatMap(JSON.Decode.array) {
      | None => body
      | Some(toolsArr) => {
          let toolsArr2 = Array.map(toolsArr, tool =>
            switch JSON.Decode.object(tool) {
            | None => tool
            | Some(toolDict) =>
              switch Dict.get(toolDict, "name")->Option.flatMap(JSON.Decode.string) {
              | Some("web_search") => f(tool)
              | _ => tool
              }
            }
          )
          let d2 = Dict.fromArray(Dict.toArray(d))
          Dict.set(d2, "tools", Json.arr(toolsArr2))
          JSON.Encode.object(d2)
        }
      }
    }

  // Reads the "type" already on the web_search tool of a built body — used
  // to label the run with what actually went out, after --search-tool and
  // --search off have had their say. None means no web_search tool at all.
  let webSearchToolTypeInBody = (body: JSON.t): option<string> =>
    switch JSON.Decode.object(body) {
    | None => None
    | Some(d) =>
      switch Dict.get(d, "tools")->Option.flatMap(JSON.Decode.array) {
      | None => None
      | Some(toolsArr) =>
        Array.reduce(toolsArr, None, (acc, tool) =>
          switch acc {
          | Some(_) => acc
          | None =>
            switch JSON.Decode.object(tool) {
            | None => None
            | Some(toolDict) =>
              switch Dict.get(toolDict, "name")->Option.flatMap(JSON.Decode.string) {
              | Some("web_search") => Dict.get(toolDict, "type")->Option.flatMap(JSON.Decode.string)
              | _ => None
              }
            }
          }
        )
      }
    }

  // Reads "allowed_callers" off the web_search tool of a built body, joined
  // with ",". "default" means the key is absent, so the API default applies.
  let callersInBody = (body: JSON.t): string =>
    switch JSON.Decode.object(body) {
    | None => "default"
    | Some(d) =>
      switch Dict.get(d, "tools")->Option.flatMap(JSON.Decode.array) {
      | None => "default"
      | Some(toolsArr) =>
        Array.reduce(toolsArr, None, (acc, tool) =>
          switch acc {
          | Some(_) => acc
          | None =>
            switch JSON.Decode.object(tool) {
            | None => None
            | Some(toolDict) =>
              switch Dict.get(toolDict, "name")->Option.flatMap(JSON.Decode.string) {
              | Some("web_search") =>
                Dict.get(toolDict, "allowed_callers")->Option.flatMap(JSON.Decode.array)
              | _ => None
              }
            }
          }
        )
        ->Option.map(callersArr => Array.filterMap(callersArr, JSON.Decode.string)->Array.join(","))
        ->Option.getOr("default")
      }
    }

  let setToolType = (toolType: string, tool: JSON.t): JSON.t =>
    switch JSON.Decode.object(tool) {
    | None => tool
    | Some(d) => {
        let d2 = Dict.fromArray(Dict.toArray(d))
        Dict.set(d2, "type", Json.str(toolType))
        JSON.Encode.object(d2)
      }
    }

  let applySearchTool = (searchTool: option<string>, body: JSON.t): JSON.t =>
    switch searchTool {
    | None => body
    | Some(t) => mapWebSearchTool(body, tool => setToolType(t, tool))
    }

  let setDirectCaller = (tool: JSON.t): JSON.t =>
    switch JSON.Decode.object(tool) {
    | None => tool
    | Some(d) => {
        let d2 = Dict.fromArray(Dict.toArray(d))
        Dict.set(d2, "allowed_callers", Json.arr([Json.str("direct")]))
        JSON.Encode.object(d2)
      }
    }

  let applyDirectSearch = (enabled: bool, body: JSON.t): JSON.t =>
    enabled ? mapWebSearchTool(body, setDirectCaller) : body

  // --dynamic-filtering: strip allowed_callers back off the web_search tool,
  // for a control run against the API default (search from a code step).
  let removeAllowedCallers = (tool: JSON.t): JSON.t =>
    switch JSON.Decode.object(tool) {
    | None => tool
    | Some(d) =>
      JSON.Encode.object(Dict.fromArray(Array.filter(Dict.toArray(d), ((k, _)) => k != "allowed_callers")))
    }

  let applyDynamicFiltering = (enabled: bool, body: JSON.t): JSON.t =>
    enabled ? mapWebSearchTool(body, removeAllowedCallers) : body

  let applyNoParallel = (enabled: bool, body: JSON.t): JSON.t =>
    if !enabled {
      body
    } else {
      switch JSON.Decode.object(body) {
      | None => body
      | Some(d) => {
          let d2 = Dict.fromArray(Dict.toArray(d))
          Dict.set(
            d2,
            "tool_choice",
            Json.obj([("type", Json.str("auto")), ("disable_parallel_tool_use", Json.boolJ(true))]),
          )
          JSON.Encode.object(d2)
        }
      }
    }

  // -- --print-body: redact the photo out of the body before printing ------

  let replaceAt = (arr: array<JSON.t>, idx: int, f: JSON.t => JSON.t): array<JSON.t> =>
    Array.mapWithIndex(arr, (v, i) => i == idx ? f(v) : v)

  let redactSource = (source: JSON.t): JSON.t =>
    switch JSON.Decode.object(source) {
    | None => source
    | Some(d) =>
      switch Dict.get(d, "data")->Option.flatMap(JSON.Decode.string) {
      | None => source
      | Some(data) => {
          let d2 = Dict.fromArray(Dict.toArray(d))
          Dict.set(d2, "data", Json.str("<" ++ Int.toString(String.length(data)) ++ " base64 chars>"))
          JSON.Encode.object(d2)
        }
      }
    }

  let redactContentBlock = (block: JSON.t): JSON.t =>
    switch JSON.Decode.object(block) {
    | None => block
    | Some(d) =>
      switch Dict.get(d, "source") {
      | None => block
      | Some(source) => {
          let d2 = Dict.fromArray(Dict.toArray(d))
          Dict.set(d2, "source", redactSource(source))
          JSON.Encode.object(d2)
        }
      }
    }

  let redactMessage = (msg: JSON.t): JSON.t =>
    switch JSON.Decode.object(msg) {
    | None => msg
    | Some(d) =>
      switch Dict.get(d, "content")->Option.flatMap(JSON.Decode.array) {
      | None => msg
      | Some(content) => {
          let content2 = replaceAt(content, 0, redactContentBlock)
          let d2 = Dict.fromArray(Dict.toArray(d))
          Dict.set(d2, "content", Json.arr(content2))
          JSON.Encode.object(d2)
        }
      }
    }

  let redactBody = (body: JSON.t): JSON.t =>
    switch JSON.Decode.object(body) {
    | None => body
    | Some(d) =>
      switch Dict.get(d, "messages")->Option.flatMap(JSON.Decode.array) {
      | None => body
      | Some(messages) => {
          let messages2 = replaceAt(messages, 0, redactMessage)
          let d2 = Dict.fromArray(Dict.toArray(d))
          Dict.set(d2, "messages", Json.arr(messages2))
          JSON.Encode.object(d2)
        }
      }
    }

  let buildBody = (~structuredOutput: bool): JSON.t => {
    let base = ClaudeClient.buildRequestBody(
      ~model=args.model,
      ~imageBase64,
      ~structuredOutput,
      ~mode=ClaudeClient.Scene({width, height}),
    )
    let afterSearch = applySearch(args.search, applySchema(args.schema, base))
    let afterPrompt = applyPromptOnestep(args.promptOnestep, afterSearch)
    let afterTool = applySearchTool(args.searchTool, afterPrompt)
    let afterCallers = applyDirectSearch(args.directSearch, afterTool)
    let afterParallel = applyNoParallel(args.noParallel, afterCallers)
    applyDynamicFiltering(args.dynamicFiltering, afterParallel)
  }

  let sampleBody = buildBody(~structuredOutput=config.structuredOutput)
  let webSearchToolType = webSearchToolTypeInBody(sampleBody)
  let callersLabel = callersInBody(sampleBody)

  if args.printBody {
    Console.log(JSON.stringify(redactBody(sampleBody)))
    Node.Process.exit(0)
  }

  let spikeDir = Node.Path.join([config.dataDir, "spike"])
  Node.Fs.mkdirSync(spikeDir, {recursive: true})
  let eventsPath = Node.Path.join([spikeDir, args.label ++ ".events.jsonl"])
  let runsPath = Node.Path.join([spikeDir, "runs.jsonl"])
  Node.Fs.writeFileSync(eventsPath, "")

  let controller = Fetch.AbortController.make()

  let headersMs = ref(None)
  let messageStartMs = ref(None)
  let inputTokensAtStart = ref(None)
  let toolStarts: Dict.t<(float, string)> = Dict.fromArray([])
  let toolLines = ref([])
  let codeStepCount = ref(0)
  let codeStepTimeouts = ref(0)
  let codeStepLongestMs = ref(None)
  let searchStarts: Dict.t<(float, option<string>)> = Dict.fromArray([])
  let searchLines = ref([])
  let firstTextDeltaMs = ref(None)
  let firstBoxMs = ref(None)
  let firstItemMs = ref(None)
  let lastItemMs = ref(None)
  let stopReason = ref("(stream did not finish)")
  let streamFailed = ref(None)
  let stopFiredMs = ref(None)

  let onHeaders = (ms: float): unit => headersMs := Some(ms)

  let onRaw = (ms: float, sseEvt: Sse.event): unit => {
    Node.Fs.appendFileSync(eventsPath, eventLine(ms, sseEvt) ++ "\n")
    if firstTextDeltaMs.contents == None && isTextDelta(sseEvt) {
      firstTextDeltaMs := Some(ms)
    }
  }

  let onEvent = (ms: float, evt: SceneStream.logEvent): unit =>
    switch evt {
    | SceneStream.ClaudeStarted({inputTokens}) => {
        messageStartMs := Some(ms)
        inputTokensAtStart := Some(inputTokens)
      }
    | SceneStream.Thinking => ()
    | SceneStream.ToolRunStarted({id, name}) => Dict.set(toolStarts, id, (ms, name))
    | SceneStream.ToolRunDone({id, name, status}) => {
        let startMs = Dict.get(toolStarts, id)->Option.map(((s, _)) => s)
        toolLines :=
          Array.concat(
            toolLines.contents,
            [
              "tool " ++
              name ++
              ": start=" ++
              fmtMs(startMs) ++
              " done=" ++
              fmtMs(Some(ms)) ++
              " status=" ++
              status->Option.getOr("-"),
            ],
          )
        if name == "code_execution" {
          codeStepCount := codeStepCount.contents + 1
          switch status {
          | Some("detection_timeout") => codeStepTimeouts := codeStepTimeouts.contents + 1
          | _ => ()
          }
          switch startMs {
          | None => ()
          | Some(s) => {
              let stepMs = ms -. s
              switch codeStepLongestMs.contents {
              | None => codeStepLongestMs := Some(stepMs)
              | Some(m) =>
                if stepMs > m {
                  codeStepLongestMs := Some(stepMs)
                }
              }
            }
          }
        }
      }
    | SceneStream.SearchStarted({id, query}) => Dict.set(searchStarts, id, (ms, query))
    | SceneStream.SearchDone({id, resultCount}) => {
        let started = Dict.get(searchStarts, id)
        let startMs = started->Option.map(((s, _)) => s)
        let query = started->Option.flatMap(((_, q)) => q)->Option.getOr("?")
        searchLines :=
          Array.concat(
            searchLines.contents,
            [
              "search \"" ++
              query ++
              "\": start=" ++
              fmtMs(startMs) ++
              " done=" ++
              fmtMs(Some(ms)) ++
              " count=" ++
              Int.toString(resultCount),
            ],
          )
      }
    | SceneStream.SearchFailed({id, errorCode}) => {
        let started = Dict.get(searchStarts, id)
        let startMs = started->Option.map(((s, _)) => s)
        let query = started->Option.flatMap(((_, q)) => q)->Option.getOr("?")
        searchLines :=
          Array.concat(
            searchLines.contents,
            [
              "search \"" ++
              query ++
              "\": start=" ++
              fmtMs(startMs) ++
              " FAILED " ++
              errorCode ++
              " at=" ++
              fmtMs(Some(ms)),
            ],
          )
      }
    | SceneStream.BoxFound(_) =>
      if firstBoxMs.contents == None {
        firstBoxMs := Some(ms)
      }
    | SceneStream.ItemFound(_) => {
        if firstItemMs.contents == None {
          firstItemMs := Some(ms)
        }
        lastItemMs := Some(ms)
        if args.stopAfterFirstItem && stopFiredMs.contents == None {
          stopFiredMs := Some(ms)
          Fetch.AbortController.abort(controller)
        }
      }
    | SceneStream.ItemRejected(_) => ()
    | SceneStream.Finished({stopReason: reason}) => stopReason := reason
    | SceneStream.StreamFailed(msg) => streamFailed := Some(msg)
    }

  let runStartMs = Date.now()
  let outcome = await ClaudeStream.run(
    ~config,
    ~buildBody,
    ~stop=Fetch.AbortController.signal(controller),
    ~onEvent,
    ~onRaw,
    ~onHeaders,
  )
  let doneMs = Date.now() -. runStartMs

  let (modelOpt, outcomeTag) = switch outcome {
  | ClaudeStream.Completed(model) => (Some(model), "completed")
  | ClaudeStream.Stopped(model) => (Some(model), "stopped")
  | ClaudeStream.TimedOut(model, _) => (Some(model), "timed_out")
  | ClaudeStream.HttpFailed(status, text) => {
      Console.log("http failed: " ++ Int.toString(status) ++ " " ++ text)
      (None, "http_failed")
    }
  | ClaudeStream.NoApiKey => {
      Console.log("no ANTHROPIC_API_KEY configured (and FIXTURES is not set)")
      (None, "no_api_key")
    }
  | ClaudeStream.StreamError(model, msg) => {
      Console.log("stream failed: " ++ msg)
      (Some(model), "stream_error")
    }
  }

  let items = modelOpt->Option.map(SceneStream.items)->Option.getOr([])
  let usage = modelOpt->Option.map(SceneStream.usage)->Option.getOr(SceneStream.emptyUsage)
  let finalText = modelOpt->Option.map(SceneStream.finalText)->Option.getOr("")

  let decodedFromFinalText = switch JsonCombinators.Json.parse(finalText) {
  | Error(_) => []
  | Ok(json) =>
    switch ClaudeClient.decodeItemsJson(json) {
    | Error(_) => []
    | Ok(decoded) => decoded
    }
  }

  let usd = Pricing.usdCost(~model=args.model, ~usage)
  let stopToEndMs = stopFiredMs.contents->Option.map(fired => doneMs -. fired)

  let summary: summary = {
    label: args.label,
    photo: args.photo,
    width,
    height,
    model: args.model,
    schema: args.schema,
    search: args.search,
    headersMs: headersMs.contents,
    messageStartMs: messageStartMs.contents,
    inputTokensAtStart: inputTokensAtStart.contents,
    toolLines: toolLines.contents,
    searchLines: searchLines.contents,
    firstTextDeltaMs: firstTextDeltaMs.contents,
    firstBoxMs: firstBoxMs.contents,
    firstItemMs: firstItemMs.contents,
    lastItemMs: lastItemMs.contents,
    doneMs: Some(doneMs),
    itemCount: Array.length(items),
    usage,
    usd,
    stopReason: stopReason.contents,
    streamFailed: streamFailed.contents,
    itemsEqualFinalDecode: claudeItemsEqual(items, decodedFromFinalText),
    outcomeTag,
    stopAfterFirstItem: args.stopAfterFirstItem,
    stopFiredMs: stopFiredMs.contents,
    stopToEndMs,
    promptOnestep: args.promptOnestep,
    webSearchToolType,
    callers: callersLabel,
    noParallel: args.noParallel,
    codeStepCount: codeStepCount.contents,
    codeStepTimeouts: codeStepTimeouts.contents,
    codeStepLongestMs: codeStepLongestMs.contents,
  }

  Array.forEach(summaryLines(summary), Console.log)
  Node.Fs.appendFileSync(runsPath, JSON.stringify(summaryJson(summary)) ++ "\n")
}

let main = async (): unit =>
  switch parseFrom(Node.Process.argv, 2, defaultArgs) {
  | Error(msg) => {
      Console.log("error: " ++ msg)
      Console.log(usageText)
      Node.Process.exit(1)
    }
  | Ok(args) if args.photo == "" || args.label == "" => {
      Console.log("error: --photo and --label are required")
      Console.log(usageText)
      Node.Process.exit(1)
    }
  | Ok(args) =>
    if !Node.Fs.existsSync(args.photo) {
      Console.log("error: photo not found: " ++ args.photo)
      Node.Process.exit(1)
    } else {
      let buf = Node.Fs.readFileBuffer(args.photo)
      switch JpegSize.dimensions(buf) {
      | None => {
          Console.log("error: could not read JPEG dimensions from: " ++ args.photo)
          Node.Process.exit(1)
        }
      | Some((width, height)) => await runSpike(~args, ~buf, ~width, ~height)
      }
    }
  }

main()->Promise.ignore
