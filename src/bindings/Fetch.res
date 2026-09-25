// Outbound HTTP: the global `fetch` (Node 18+) plus a couple of small
// globals (AbortSignal.timeout, btoa) needed by the Claude and eBay clients.
// Modeled on dippa's src/bindings/Http.res, adapted from the Workers fetch
// shape to the identical WHATWG fetch available globally in Node.

type response

module AbortSignal = {
  type t
  @val @scope("AbortSignal") external timeout: int => t = "timeout"
}

type requestInit = {
  method?: string,
  headers?: dict<string>,
  body?: string,
  signal?: AbortSignal.t,
}

@val external fetch: (string, ~init: requestInit=?) => promise<response> = "fetch"

// A second typed binding for the same global `fetch`, for a binary
// (Buffer) request body — Node's fetch (undici) accepts a Buffer as-is,
// byte for byte, where a plain-string body would get re-encoded as UTF-8
// and corrupt bytes over 0x7f. Tests use this to POST a real JPEG.
type requestInitBuffer = {
  method?: string,
  headers?: dict<string>,
  body?: Node.Buffer.t,
  signal?: AbortSignal.t,
}

@val external fetchBuffer: (string, ~init: requestInitBuffer=?) => promise<response> = "fetch"

@get external status: response => int = "status"
@get external ok: response => bool = "ok"
@send external text: response => promise<string> = "text"
@send external json: response => promise<JSON.t> = "json"

// Basic-auth header value for the eBay client-credentials grant.
@val external btoa: string => string = "btoa"

type headers

@get external responseHeaders: response => headers = "headers"

@send external getHeader: (headers, string) => Nullable.t<string> = "get"
