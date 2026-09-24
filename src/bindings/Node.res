// Node.js built-in module bindings used by the reflip brain. Typed externals
// only, per CLAUDE.md's ReScript house rules: no %raw, no Obj.magic, no
// %identity, no untyped externals.

module Buffer = {
  type t

  @val @scope("Buffer") external concat: array<t> => t = "concat"
  @send external toStringWithEncoding: (t, string) => string = "toString"
  @get external length: t => int = "length"
}

module Fs = {
  @module("node:fs") external existsSync: string => bool = "existsSync"
  @module("node:fs") external readFileBuffer: string => Buffer.t = "readFileSync"
  @module("node:fs") external readFileUtf8: (string, string) => string = "readFileSync"
  @module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
  @module("node:fs") external appendFileSync: (string, string) => unit = "appendFileSync"

  type mkdirOptions = {recursive: bool}
  @module("node:fs") external mkdirSync: (string, mkdirOptions) => unit = "mkdirSync"
}

module Path = {
  @module("node:path") @variadic external join: array<string> => string = "join"
}

module Process = {
  @scope("process") @val external env: dict<string> = "env"
  @scope("process") @val external cwd: unit => string = "cwd"
}

module Crypto = {
  @module("node:crypto") external randomUUID: unit => string = "randomUUID"
}

module Os = {
  @module("node:os") external tmpdir: unit => string = "tmpdir"
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

  @send external writeHead: (response, int, dict<string>) => unit = "writeHead"
  @send external endWithBody: (response, string) => unit = "end"

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
