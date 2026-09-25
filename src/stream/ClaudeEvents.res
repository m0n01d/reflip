// Decodes one parsed SSE event's `data` JSON into a typed streaming
// event, keyed off its "type" field. This is the edge: JSON.t goes in,
// typed values come out, through @glennsl/rescript-json-combinators.

module D = JsonCombinators.Json.Decode

type webSearchOutcome = Results(int) | SearchError(string)
type codeRun = {returnCode: option<int>, status: option<string>}
type blockStart =
  | TextStart
  | ThinkingStart
  | ServerToolUseStart({id: string, name: string, callerId: option<string>, input: option<JSON.t>})
  | WebSearchResult({toolUseId: string, outcome: webSearchOutcome})
  | CodeExecutionResult({toolUseId: string, run: codeRun})
  | OtherBlock(string)
type delta =
  | TextDelta(string)
  | InputJsonDelta(string)
  | ThinkingDelta
  | SignatureDelta
  | OtherDelta(string)
type t =
  | MessageStart({model: string, usage: Types.usage})
  | BlockStart({index: int, block: blockStart})
  | BlockDelta({index: int, delta: delta})
  | BlockStop({index: int})
  | MessageDelta({stopReason: option<string>, usage: Types.usage})
  | MessageStop
  | Ping
  | ApiError({errorType: string, message: string})
  | Unknown(string)

// option<option<'a>> collapses to option<'a> — needed wherever a field is
// itself only sometimes present (e.g. "caller") and we also want an
// optional value out of it (e.g. "tool_id" on that object). `optional`
// only catches an absent key; it re-raises a failure from inside the
// nested decoder, so the inner field also uses `.optional`.
let flatten = (o: option<option<'a>>): option<'a> =>
  switch o {
  | Some(x) => x
  | None => None
  }

let usageDecoder: D.t<Types.usage> = D.object(field => {
  let webSearchRequests =
    flatten(
      field.optional("server_tool_use", D.object(f2 => f2.optional("web_search_requests", D.int))),
    )->Option.getOr(0)
  {
    Types.inputTokens: field.optional("input_tokens", D.int)->Option.getOr(0),
    outputTokens: field.optional("output_tokens", D.int)->Option.getOr(0),
    cacheReadInputTokens: field.optional("cache_read_input_tokens", D.int)->Option.getOr(0),
    cacheCreationInputTokens: field.optional("cache_creation_input_tokens", D.int)->Option.getOr(0),
    webSearchRequests,
  }
})

let messageStartDecoder: D.t<t> = D.object(field =>
  field.required(
    "message",
    D.object(f2 =>
      MessageStart({model: f2.required("model", D.string), usage: f2.required("usage", usageDecoder)})
    ),
  )
)

let webSearchOutcomeDecoder: D.t<webSearchOutcome> = D.oneOf([
  D.array(D.id)->D.map(arr => Results(Array.length(arr))),
  D.object(field => SearchError(field.required("error_code", D.string))),
])

let statusFromStdout = (stdout: string): option<string> =>
  switch JsonCombinators.Json.parse(stdout) {
  | Error(_) => None
  | Ok(json) =>
      switch JsonCombinators.Json.decode(json, D.object(f => f.optional("status", D.string))) {
      | Ok(status) => status
      | Error(_) => None
      }
  }

let codeRunDecoder: D.t<codeRun> = D.object(field => {
  returnCode: field.optional("return_code", D.int),
  status: field.optional("stdout", D.string)->Option.flatMap(statusFromStdout),
})

let blockDecoder: D.t<blockStart> = D.object(field =>
  switch field.required("type", D.string) {
  | "text" => TextStart
  | "thinking" => ThinkingStart
  | "server_tool_use" =>
      ServerToolUseStart({
        id: field.required("id", D.string),
        name: field.required("name", D.string),
        callerId: flatten(field.optional("caller", D.object(f2 => f2.optional("tool_id", D.string)))),
        input: field.optional("input", D.id),
      })
  | "web_search_tool_result" =>
      WebSearchResult({
        toolUseId: field.required("tool_use_id", D.string),
        outcome: field.required("content", webSearchOutcomeDecoder),
      })
  | "code_execution_tool_result" =>
      CodeExecutionResult({
        toolUseId: field.required("tool_use_id", D.string),
        run: field.required("content", codeRunDecoder),
      })
  | other => OtherBlock(other)
  }
)

let blockStartDecoder: D.t<t> = D.object(field =>
  BlockStart({index: field.required("index", D.int), block: field.required("content_block", blockDecoder)})
)

let deltaKindDecoder: D.t<delta> = D.object(field =>
  switch field.required("type", D.string) {
  | "text_delta" => TextDelta(field.required("text", D.string))
  | "input_json_delta" => InputJsonDelta(field.required("partial_json", D.string))
  | "thinking_delta" => ThinkingDelta
  | "signature_delta" => SignatureDelta
  | other => OtherDelta(other)
  }
)

let blockDeltaDecoder: D.t<t> = D.object(field =>
  BlockDelta({index: field.required("index", D.int), delta: field.required("delta", deltaKindDecoder)})
)

let blockStopDecoder: D.t<t> = D.object(field => BlockStop({index: field.required("index", D.int)}))

let messageDeltaDecoder: D.t<t> = D.object(field =>
  MessageDelta({
    stopReason: field.required("delta", D.object(f2 => f2.optional("stop_reason", D.string))),
    usage: field.required("usage", usageDecoder),
  })
)

let errorDecoder: D.t<t> = D.object(field =>
  field.required(
    "error",
    D.object(f2 =>
      ApiError({errorType: f2.required("type", D.string), message: f2.required("message", D.string)})
    ),
  )
)

let decode = (event: Sse.event): result<t, string> =>
  switch JsonCombinators.Json.parse(event.data) {
  | Error(msg) => Error(msg)
  | Ok(json) =>
      switch JsonCombinators.Json.decode(json, D.field("type", D.string)) {
      | Error(msg) => Error(msg)
      | Ok("ping") => Ok(Ping)
      | Ok("message_stop") => Ok(MessageStop)
      | Ok("message_start") => JsonCombinators.Json.decode(json, messageStartDecoder)
      | Ok("content_block_start") => JsonCombinators.Json.decode(json, blockStartDecoder)
      | Ok("content_block_delta") => JsonCombinators.Json.decode(json, blockDeltaDecoder)
      | Ok("content_block_stop") => JsonCombinators.Json.decode(json, blockStopDecoder)
      | Ok("message_delta") => JsonCombinators.Json.decode(json, messageDeltaDecoder)
      | Ok("error") => JsonCombinators.Json.decode(json, errorDecoder)
      | Ok(other) => Ok(Unknown(other))
      }
  }
