// Node.js built-in module bindings used by the reflip brain. Typed externals
// only, per CLAUDE.md's ReScript house rules: no %raw, no Obj.magic, no
// %identity, no untyped externals.

module Buffer = {
  type t

  @val @scope("Buffer") external concat: array<t> => t = "concat"
  @send external toStringWithEncoding: (t, string) => string = "toString"
  @get external length: t => int = "length"
  @send external readUInt8: (t, int) => int = "readUInt8"
  @send external readUInt16BE: (t, int) => int = "readUInt16BE"

  @val @scope("Buffer") external fromString: (string, string) => t = "from"

  // For a fetch response body read with `.arrayBuffer()` (Fetch.res) —
  // opaque on this side, since nothing here inspects it, only converts it.
  type arrayBufferLike
  @val @scope("Buffer") external fromArrayBuffer: arrayBufferLike => t = "from"
}

module Fs = {
  @module("node:fs") external existsSync: string => bool = "existsSync"
  @module("node:fs") external readFileBuffer: string => Buffer.t = "readFileSync"
  @module("node:fs") external readFileUtf8: (string, string) => string = "readFileSync"
  @module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
  // Same underlying "writeFileSync", a second typed binding for the Buffer
  // overload — needed to save an uploaded photo's raw JPEG bytes without
  // corrupting them through a string round-trip (mirrors Server.res's
  // endWithBuffer, the equivalent split for "end").
  @module("node:fs") external writeFileBuffer: (string, Buffer.t) => unit = "writeFileSync"
  @module("node:fs") external appendFileSync: (string, string) => unit = "appendFileSync"

  type mkdirOptions = {recursive: bool}
  @module("node:fs") external mkdirSync: (string, mkdirOptions) => unit = "mkdirSync"

  @module("node:fs") external copyFileSync: (string, string) => unit = "copyFileSync"
  // Removes the intermediate crop file Crop.res writes next to its dest.
  @module("node:fs") external unlinkSync: string => unit = "unlinkSync"
  // Used by CropTest.res to prove the intermediate crop file is gone.
  @module("node:fs") external readdirSync: string => array<string> = "readdirSync"
}

module Path = {
  @module("node:path") @variadic external join: array<string> => string = "join"
}

module Process = {
  @scope("process") @val external env: dict<string> = "env"
  @scope("process") @val external cwd: unit => string = "cwd"
  // Used by EmailCheck.res to report a clean 0/1 status instead of an
  // uncaught-rejection stack trace.
  @scope("process") @val external exit: int => unit = "exit"
  // [execPath, scriptPath, ...userArgs] -- StreamSpike.res slices off the
  // first two to get just the flags the caller passed after the script name.
  @scope("process") @val external argv: array<string> = "argv"
}

module Crypto = {
  @module("node:crypto") external randomUUID: unit => string = "randomUUID"
}

module Os = {
  @module("node:os") external tmpdir: unit => string = "tmpdir"
}

// The global timer, used by HaulWorker.res to retry after a 429/529 without
// blocking the queue (`setTimeout(kick, retryMs)` in docs/spec-haul-mode.md
// "Step 3: brain queue"). No `clearTimeout` binding: every scheduled retry
// is short (`haulRetryMs`) and only ever set on a path that itself required
// this exact timer to fire before the worker can look at that haul again,
// so nothing needs to cancel it early.
module Timer = {
  @val external setTimeout: (unit => unit, int) => unit = "setTimeout"
}

module Url = {
  type t
  @new external make: (string, string) => t = "URL"
  @get external pathname: t => string = "pathname"

  type searchParams
  @get external searchParams: t => searchParams = "searchParams"
  @send external getParam: (searchParams, string) => Nullable.t<string> = "get"
}

module HttpServer = {
  type request
  type response
  type server

  @get external method: request => string = "method"
  @get external url: request => string = "url"
  // Simplification: we only ever read a single-value header (content-type).
  // Node types header values as string | string[] | undefined for the rare
  // multi-value case, which this server never hits.
  @get external headers: request => dict<string> = "headers"

  @send external onData: (request, string, Buffer.t => unit) => unit = "on"
  @send external onEnd: (request, string, unit => unit) => unit = "on"
  // The stub Claude server in ClaudeStream tests: fires when the incoming
  // request's underlying connection is terminated, so a test can see that
  // an aborted downstream fetch (StreamRoute.res) really tore down the
  // upstream connection to it too.
  @send external onRequestClose: (request, string, unit => unit) => unit = "on"

  @send external writeHead: (response, int, dict<string>) => unit = "writeHead"
  @send external endWithBody: (response, string) => unit = "end"

  // StreamRoute.res: write one SSE chunk without ending the response, force
  // the headers out immediately (tailscale serve, a Go reverse proxy, only
  // flushes a text/event-stream response once headers are on the wire), and
  // tell whether "end" was already called — so a late write (a heartbeat, or
  // an event still in flight when the client disconnects) is a no-op instead
  // of a write-after-end throw.
  @send external write: (response, string) => unit = "write"
  @send external flushHeaders: response => unit = "flushHeaders"
  @get external writableEnded: response => bool = "writableEnded"
  // Server.res's server-level error handler: once StreamRoute.handle has
  // already sent the SSE 200 headers, a later uncaught rejection must not
  // call writeHead again (Node throws ERR_HTTP_HEADERS_SENT for that). This
  // says whether the headers already went out.
  @get external headersSent: response => bool = "headersSent"
  // Test-only: StreamRouteTest.res's stub Claude server uses this to
  // simulate a connection dropping mid-stream — a plain "end" is a clean
  // finish, not the failure that test needs.
  @send external destroy: response => unit = "destroy"
  // Fires on a premature disconnect (checked via writableEnded above) and
  // also once normally after our own "end" finishes flushing — the caller
  // tells the two apart. A no-op "error" listener too: Node treats an
  // unlistened "error" event as an uncaught exception, and a response
  // being written to after the client aborted the connection can raise one.
  @send external onClose: (response, string, unit => unit) => unit = "on"
  @send external onResponseError: (response, string, unit => unit) => unit = "on"

  @module("node:http")
  external createServer: ((request, response) => unit) => server = "createServer"
  @send external listen: (server, int, string, unit => unit) => unit = "listen"
  @send external close: (server, unit => unit) => unit = "close"

  type addressInfo = {port: int}
  @send external address: server => addressInfo = "address"

  // Collects the whole request body into one Buffer. Fine for a personal
  // tool handling one photo at a time; not meant for large concurrent load.
  let readBody = (req: request): promise<Buffer.t> =>
    Promise.make((resolve, _reject) => {
      let chunks: array<Buffer.t> = []
      onData(req, "data", chunk => Array.push(chunks, chunk))
      onEnd(req, "end", () => resolve(Buffer.concat(chunks)))
    })
}
