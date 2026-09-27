// The shared contract for every SSE event POST /api/scene/stream sends.
// Node-free: src/web/ imports this module into the page bundle, same as
// Shared.res. See docs/stream-spike.md §3 for the event table this
// mirrors, and docs/scan-ui.md §2 for the full, current contract.
//
// StreamRoute.res is the only writer: it builds a `t`, encodes it with
// `toSse`, and sends the (name, data) pair through Sse.encode. The page
// is the reader: it feeds raw SSE text through Sse.feed and decodes each
// event with `decode`. Names and fields come from StreamRoute.res and
// SceneStream.res as they already send them — nothing here is renamed.
//
// The spot-* events and `end` are declared for the next agent to emit;
// this wave only wires `end` into the route (see StreamRoute.res).

module D = JsonCombinators.Json.Decode

module EndStatus = {
  // done: the scene finished and sent `scene`. stopped: the client closed
  // the connection. failed: the Claude request itself failed (a non-200,
  // or no API key). timeout: the 180 s limit hit first.
  type t = Done | Stopped | Failed | Timeout

  let toString = (status: t): string =>
    switch status {
    | Done => "done"
    | Stopped => "stopped"
    | Failed => "failed"
    | Timeout => "timeout"
    }

  let fromString = (s: string): option<t> =>
    switch s {
    | "done" => Some(Done)
    | "stopped" => Some(Stopped)
    | "failed" => Some(Failed)
    | "timeout" => Some(Timeout)
    | _ => None
    }
}

type t =
  | PhotoReceived({sceneId: string, bytes: int, width: int, height: int})
  | ClaudeStarted({t: float, inputTokens: int})
  | Thinking({t: float})
  | ToolRun({t: float, id: string, name: string})
  | ToolDone({t: float, id: string, name: string, status: option<string>})
  | SearchStarted({t: float, id: string, query: option<string>})
  | SearchDone({t: float, id: string, count: int})
  | SearchFailed({t: float, id: string, errorCode: string})
  | Box({t: float, index: int, box: array<int>})
  | Item({t: float, index: int, item: Types.replyItem})
  | Done({claudeMs: float, inputTokens: int, outputTokens: int, webSearches: int, usd: float})
  | Scene(Types.sceneReply)
  // Named ErrorEvent, not Error: this file returns `result<t, string>`
  // throughout, and a bare `Error` constructor on `t` sitting next to
  // `result`'s own `Error` reads badly and invites mistakes.
  | ErrorEvent({t: float, message: string})
  | Stop({t: float})
  | SpotStarted({t: float, inputTokens: int})
  | SpotItem({t: float, index: int, name: string, box: array<int>})
  | SpotDone({t: float, claudeMs: float, inputTokens: int, outputTokens: int, usd: float})
  | SpotFailed({t: float, message: string})
  | End({t: float, status: EndStatus.t})

let toSse = (evt: t): (string, JSON.t) =>
  switch evt {
  | PhotoReceived({sceneId, bytes, width, height}) => (
      "photo-received",
      Json.obj([
        ("sceneId", Json.str(sceneId)),
        ("bytes", Json.num(Int.toFloat(bytes))),
        ("width", Json.num(Int.toFloat(width))),
        ("height", Json.num(Int.toFloat(height))),
      ]),
    )
  | ClaudeStarted({t, inputTokens}) => (
      "claude-started",
      Json.obj([("t", Json.num(t)), ("inputTokens", Json.num(Int.toFloat(inputTokens)))]),
    )
  | Thinking({t}) => ("thinking", Json.obj([("t", Json.num(t))]))
  | ToolRun({t, id, name}) => (
      "tool-run",
      Json.obj([("t", Json.num(t)), ("id", Json.str(id)), ("name", Json.str(name))]),
    )
  | ToolDone({t, id, name, status}) => (
      "tool-done",
      Json.obj([
        ("t", Json.num(t)),
        ("id", Json.str(id)),
        ("name", Json.str(name)),
        ("status", Types.encodeOptString(status)),
      ]),
    )
  | SearchStarted({t, id, query}) => (
      "search-started",
      Json.obj([("t", Json.num(t)), ("id", Json.str(id)), ("query", Types.encodeOptString(query))]),
    )
  | SearchDone({t, id, count}) => (
      "search-done",
      Json.obj([("t", Json.num(t)), ("id", Json.str(id)), ("count", Json.num(Int.toFloat(count)))]),
    )
  | SearchFailed({t, id, errorCode}) => (
      "search-failed",
      Json.obj([("t", Json.num(t)), ("id", Json.str(id)), ("errorCode", Json.str(errorCode))]),
    )
  | Box({t, index, box}) => (
      "box",
      Json.obj([
        ("t", Json.num(t)),
        ("index", Json.num(Int.toFloat(index))),
        ("box", Json.arr(Array.map(box, n => Json.num(Int.toFloat(n))))),
      ]),
    )
  | Item({t, index, item}) => (
      "item",
      Json.obj([
        ("t", Json.num(t)),
        ("index", Json.num(Int.toFloat(index))),
        ("item", Types.encodeReplyItem(item)),
      ]),
    )
  | Done({claudeMs, inputTokens, outputTokens, webSearches, usd}) => (
      "done",
      Json.obj([
        ("claudeMs", Json.num(claudeMs)),
        ("inputTokens", Json.num(Int.toFloat(inputTokens))),
        ("outputTokens", Json.num(Int.toFloat(outputTokens))),
        ("webSearches", Json.num(Int.toFloat(webSearches))),
        ("usd", Json.num(usd)),
      ]),
    )
  | Scene(reply) => ("scene", Types.encodeSceneReply(reply))
  | ErrorEvent({t, message}) => (
      "error",
      Json.obj([("t", Json.num(t)), ("message", Json.str(message))]),
    )
  | Stop({t}) => ("stop", Json.obj([("t", Json.num(t))]))
  | SpotStarted({t, inputTokens}) => (
      "spot-started",
      Json.obj([("t", Json.num(t)), ("inputTokens", Json.num(Int.toFloat(inputTokens)))]),
    )
  | SpotItem({t, index, name, box}) => (
      "spot-item",
      Json.obj([
        ("t", Json.num(t)),
        ("index", Json.num(Int.toFloat(index))),
        ("name", Json.str(name)),
        ("box", Json.arr(Array.map(box, n => Json.num(Int.toFloat(n))))),
      ]),
    )
  | SpotDone({t, claudeMs, inputTokens, outputTokens, usd}) => (
      "spot-done",
      Json.obj([
        ("t", Json.num(t)),
        ("claudeMs", Json.num(claudeMs)),
        ("inputTokens", Json.num(Int.toFloat(inputTokens))),
        ("outputTokens", Json.num(Int.toFloat(outputTokens))),
        ("usd", Json.num(usd)),
      ]),
    )
  | SpotFailed({t, message}) => (
      "spot-failed",
      Json.obj([("t", Json.num(t)), ("message", Json.str(message))]),
    )
  | End({t, status}) => (
      "end",
      Json.obj([("t", Json.num(t)), ("status", Json.str(EndStatus.toString(status)))]),
    )
  }

let decode = (~event: string, ~data: string): result<t, string> =>
  switch JsonCombinators.Json.parse(data) {
  | Error(msg) => Error(msg)
  | Ok(json) =>
      switch event {
      | "photo-received" =>
          JsonCombinators.Json.decode(
            json,
            D.object(field =>
              PhotoReceived({
                sceneId: field.required("sceneId", D.string),
                bytes: field.required("bytes", D.int),
                width: field.required("width", D.int),
                height: field.required("height", D.int),
              })
            ),
          )
      | "claude-started" =>
          JsonCombinators.Json.decode(
            json,
            D.object(field =>
              ClaudeStarted({
                t: field.required("t", D.float),
                inputTokens: field.required("inputTokens", D.int),
              })
            ),
          )
      | "thinking" =>
          JsonCombinators.Json.decode(
            json,
            D.object(field => Thinking({t: field.required("t", D.float)})),
          )
      | "tool-run" =>
          JsonCombinators.Json.decode(
            json,
            D.object(field =>
              ToolRun({
                t: field.required("t", D.float),
                id: field.required("id", D.string),
                name: field.required("name", D.string),
              })
            ),
          )
      | "tool-done" =>
          JsonCombinators.Json.decode(
            json,
            D.object(field =>
              ToolDone({
                t: field.required("t", D.float),
                id: field.required("id", D.string),
                name: field.required("name", D.string),
                status: field.required("status", D.option(D.string)),
              })
            ),
          )
      | "search-started" =>
          JsonCombinators.Json.decode(
            json,
            D.object(field =>
              SearchStarted({
                t: field.required("t", D.float),
                id: field.required("id", D.string),
                query: field.required("query", D.option(D.string)),
              })
            ),
          )
      | "search-done" =>
          JsonCombinators.Json.decode(
            json,
            D.object(field =>
              SearchDone({
                t: field.required("t", D.float),
                id: field.required("id", D.string),
                count: field.required("count", D.int),
              })
            ),
          )
      | "search-failed" =>
          JsonCombinators.Json.decode(
            json,
            D.object(field =>
              SearchFailed({
                t: field.required("t", D.float),
                id: field.required("id", D.string),
                errorCode: field.required("errorCode", D.string),
              })
            ),
          )
      | "box" =>
          JsonCombinators.Json.decode(
            json,
            D.object(field =>
              Box({
                t: field.required("t", D.float),
                index: field.required("index", D.int),
                box: field.required("box", D.array(D.int)),
              })
            ),
          )
      | "item" =>
          switch (Json.floatField(json, "t"), Json.intField(json, "index"), Json.field(json, "item")) {
          | (Some(t), Some(index), Some(itemJson)) =>
              switch Shared.decodeReplyItem(itemJson) {
              | Ok(item) => Ok(Item({t, index, item}))
              | Error(msg) => Error(msg)
              }
          | _ => Error("item event missing a required field")
          }
      | "done" =>
          JsonCombinators.Json.decode(
            json,
            D.object(field =>
              Done({
                claudeMs: field.required("claudeMs", D.float),
                inputTokens: field.required("inputTokens", D.int),
                outputTokens: field.required("outputTokens", D.int),
                webSearches: field.required("webSearches", D.int),
                usd: field.required("usd", D.float),
              })
            ),
          )
      | "scene" =>
          switch Shared.decodeSceneReply(json) {
          | Ok(reply) => Ok(Scene(reply))
          | Error(msg) => Error(msg)
          }
      | "error" =>
          JsonCombinators.Json.decode(
            json,
            D.object(field =>
              ErrorEvent({
                t: field.required("t", D.float),
                message: field.required("message", D.string),
              })
            ),
          )
      | "stop" =>
          JsonCombinators.Json.decode(json, D.object(field => Stop({t: field.required("t", D.float)})))
      | "spot-started" =>
          JsonCombinators.Json.decode(
            json,
            D.object(field =>
              SpotStarted({
                t: field.required("t", D.float),
                inputTokens: field.required("inputTokens", D.int),
              })
            ),
          )
      | "spot-item" =>
          JsonCombinators.Json.decode(
            json,
            D.object(field =>
              SpotItem({
                t: field.required("t", D.float),
                index: field.required("index", D.int),
                name: field.required("name", D.string),
                box: field.required("box", D.array(D.int)),
              })
            ),
          )
      | "spot-done" =>
          JsonCombinators.Json.decode(
            json,
            D.object(field =>
              SpotDone({
                t: field.required("t", D.float),
                claudeMs: field.required("claudeMs", D.float),
                inputTokens: field.required("inputTokens", D.int),
                outputTokens: field.required("outputTokens", D.int),
                usd: field.required("usd", D.float),
              })
            ),
          )
      | "spot-failed" =>
          JsonCombinators.Json.decode(
            json,
            D.object(field =>
              SpotFailed({
                t: field.required("t", D.float),
                message: field.required("message", D.string),
              })
            ),
          )
      | "end" =>
          switch JsonCombinators.Json.decode(
            json,
            D.object(field => (field.required("t", D.float), field.required("status", D.string))),
          ) {
          | Error(msg) => Error(msg)
          | Ok((t, statusStr)) =>
              switch EndStatus.fromString(statusStr) {
              | Some(status) => Ok(End({t, status}))
              | None => Error("end event has an unknown status: " ++ statusStr)
              }
          }
      | other => Error("unknown SSE event name: " ++ other)
      }
  }
