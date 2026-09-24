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

@get external status: response => int = "status"
@get external ok: response => bool = "ok"
@send external text: response => promise<string> = "text"
@send external json: response => promise<JSON.t> = "json"

// Basic-auth header value for the eBay client-credentials grant.
@val external btoa: string => string = "btoa"
