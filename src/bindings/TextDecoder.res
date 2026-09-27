// The global `TextDecoder` (available in Node 18+ without an import),
// used to turn the Uint8Array chunks off a fetch response body's reader
// into UTF-8 text. `decode` is called once per chunk with `{stream: true}`
// so a multi-byte character split across two chunks decodes correctly;
// `flush` is the zero-argument call the spec uses to emit any bytes still
// held back once the stream itself has ended.

type t

@new external make: unit => t = "TextDecoder"

type decodeOptions = {stream: bool}

@send external decodeStream: (t, Fetch.Uint8Array.t, decodeOptions) => string = "decode"

// The zero-argument overload of the same method, bound separately since
// ReScript externals are fixed-arity.
@send external flush: t => string = "decode"
