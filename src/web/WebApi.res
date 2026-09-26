// Typed browser bindings for the parts of the platform the phone page
// needs: performance.now, createImageBitmap (with EXIF-aware orientation —
// verified 2026-09-24 against caniuse: "from-image" is the current spec
// default and has shipped in Safari/iOS Safari since 16.0), a detached
// <canvas> to resize and re-encode a photo, file-input access, and fetch.
// No @rescript/webapi (npm only ships alpha/experimental prereleases, no
// stable release, checked 2026-09-24) and nothing reusable in ~/code/dippa
// (its bindings are Cloudflare-Worker-side: D1, Http, Queues, Runtime,
// Timers, WebStreams — no DOM). Per reflip's CLAUDE.md: proper typed
// bindings, no %raw/%%raw/Obj.magic/%identity.

@scope("performance") @val external now: unit => float = "now"

type blob
@get external blobSize: blob => int = "size"

type imageBitmap
type imageBitmapOptions = {imageOrientation: string}
@val
external createImageBitmap: (blob, imageBitmapOptions) => promise<imageBitmap> = "createImageBitmap"
@get external bitmapWidth: imageBitmap => int = "width"
@get external bitmapHeight: imageBitmap => int = "height"

type canvasElement
type context2d
type document
@val external document: document = "document"
@send external createElement: (document, string) => canvasElement = "createElement"
@set external setCanvasWidth: (canvasElement, int) => unit = "width"
@set external setCanvasHeight: (canvasElement, int) => unit = "height"
@send external getContext2d: (canvasElement, string) => Nullable.t<context2d> = "getContext"
@send
external drawImage: (context2d, imageBitmap, float, float, float, float) => unit = "drawImage"
// canvas.toBlob(callback, type, quality) — callback-based per spec; Resize.res
// wraps this in a promise. The callback receives null if encoding fails.
@send external toBlobRaw: (canvasElement, Nullable.t<blob> => unit, string, float) => unit = "toBlob"

// A file <input>'s change event target, and a <select>'s change event
// target — both read through the same opaque type since this file only
// ever calls .files on the former and .value on the latter.
type formElement
@get external eventTarget: ReactEvent.Form.t => formElement = "target"
@get external targetValue: formElement => string = "value"
type fileList
@get external targetFiles: formElement => Nullable.t<fileList> = "files"
@get external fileListLength: fileList => int = "length"
@get_index external fileListItem: (fileList, int) => Nullable.t<blob> = ""

type response
type requestInitBlob = {method: string, headers: Dict.t<string>, body: blob}
type requestInitString = {method: string, headers: Dict.t<string>, body: string}
@val external fetchBlob: (string, requestInitBlob) => promise<response> = "fetch"
@val external fetchString: (string, requestInitString) => promise<response> = "fetch"
@get external responseOk: response => bool = "ok"
@get external responseStatus: response => int = "status"
@send external responseJson: response => promise<JSON.t> = "json"
@val external fetchGet: string => promise<response> = "fetch"

// -- Haul mode (docs/spec-haul-mode.md "Step 5: phone") -------------------

// crypto.randomUUID gives each queued photo its own client id, independent
// of the server's scene id (the server echoes the same scene id back for a
// retried client id, so this never costs a duplicate Claude call).
@scope("crypto") @val external randomUUID: unit => string = "randomUUID"

// Browser timers, for the upload retry backoff and the status poll. The
// handle is window.setTimeout/setInterval's return value (a number) — this
// file is browser-only, so it is never Node's Timeout object.
@val external setTimeout: (unit => unit, int) => float = "setTimeout"
@val external clearTimeout: float => unit = "clearTimeout"
@val external setInterval: (unit => unit, int) => float = "setInterval"
@val external clearInterval: float => unit = "clearInterval"

@get external blobType: blob => string = "type"

// A Blob constructor: lets AppStateTest build a real queue item without a
// cast, and lets product code make a typed placeholder blob if it ever
// needs one.
type blobOptions = {@as("type") type_: string}
@new external makeBlobWithType: (array<string>, blobOptions) => blob = "Blob"

// Turn the "Add photos" multi-picker's FileList into a plain array, in
// order. Reuses the same fileListItem/fileListLength externals as the
// single-photo picker.
let fileListToArray = (files: fileList): array<blob> => {
  let result = []
  for i in 0 to fileListLength(files) - 1 {
    switch fileListItem(files, i)->Nullable.toOption {
    | Some(f) => Array.push(result, f)
    | None => ()
    }
  }
  result
}

// -- idb-keyval, typed honestly --------------------------------------------
// idb-keyval's get/set/keys are generic over `any` at the JS side. Rather
// than assert our own blob/string type onto whatever comes back — that
// would be Obj.magic under another name — `idbValue` is a fully opaque
// "value of unknown shape". The only way to use one is to reify it through
// the platform: `new Response(value)` accepts any BodyInit-ish value, and
// `.text()` / `.blob()` genuinely re-derive a real string or Blob from it.
// That is a runtime conversion, not a type-level cast: if the stored value
// were not blob-shaped, `.blob()` would still hand back *some* real Blob
// (never our asserted type for free), which is exactly the honesty this
// file's own header comment asks for.
type idbValue
@module("idb-keyval") external idbGetUnknown: string => promise<Nullable.t<idbValue>> = "get"
@module("idb-keyval") external idbSetBlob: (string, blob) => promise<unit> = "set"
@module("idb-keyval") external idbSetString: (string, string) => promise<unit> = "set"
@module("idb-keyval") external idbDel: string => promise<unit> = "del"
@module("idb-keyval") external idbKeysUnknown: unit => promise<array<idbValue>> = "keys"

@new external responseOfUnknown: idbValue => response = "Response"
@send external responseBlob: response => promise<blob> = "blob"
@send external responseText: response => promise<string> = "text"

let unknownToBlob = (v: idbValue): promise<blob> => responseOfUnknown(v)->responseBlob
let unknownToText = (v: idbValue): promise<string> => responseOfUnknown(v)->responseText

// An object URL for the resized photo blob, so the result view can show it
// via <img src> with no re-read of the file. Created once per photo in
// App.res's runPhotoFlow; revoked in onFileChange when a new photo replaces
// it (see AppState.res's PhotoUrlReady and StartPhoto).
@scope("URL") @val external createObjectURL: blob => string = "createObjectURL"
@scope("URL") @val external revokeObjectURL: string => unit = "revokeObjectURL"

// A generic DOM element, opaque like `formElement` above — used only for
// the item-box view: the photo's on-screen rect (to convert a tap to photo
// pixels), and scrolling a card or the photo into view on selection.
type element
type domRect = {left: float, top: float, width: float, height: float}
@send external getBoundingClientRect: element => domRect = "getBoundingClientRect"
type scrollIntoViewOptions = {behavior: string, block: string}
@send external scrollIntoView: (element, scrollIntoViewOptions) => unit = "scrollIntoView"
@send external getElementById: (document, string) => Nullable.t<element> = "getElementById"
// The click target of a photo tap, read straight off the event — same
// pattern as `eventTarget` above, for the other React event type.
@get external mouseCurrentTarget: ReactEvent.Mouse.t => element = "currentTarget"

// -- Streaming scan (docs/scan-ui.md) --------------------------------------
// ScanApi.res's typed bindings: an abortable fetch (POST with a body, and a
// plain GET, for the reconnect), a stream reader, and a TextDecoder in
// "stream" mode — the same shapes as src/bindings/Fetch.res and
// src/bindings/TextDecoder.res, but bound fresh here against the browser's
// own fetch/TextDecoder globals rather than reused from src/bindings (that
// folder is Node-only, per its own header comments).

type abortController
type abortSignal
@new external makeAbortController: unit => abortController = "AbortController"
@get external abortSignalOf: abortController => abortSignal = "signal"
@send external abortControllerAbort: abortController => unit = "abort"

type requestInitBlobSignal = {method: string, headers: Dict.t<string>, body: blob, signal: abortSignal}
@val external fetchBlobSignal: (string, requestInitBlobSignal) => promise<response> = "fetch"

type requestInitSignal = {signal: abortSignal}
@val external fetchGetSignal: (string, requestInitSignal) => promise<response> = "fetch"

// Opaque: a chunk is only ever handed to TextDecoder.decode, never
// inspected byte by byte — same convention as src/bindings/Fetch.res.
type byteChunk
type readableStream
type readableStreamReader
@get external streamBodyRaw: response => Nullable.t<readableStream> = "body"
let streamBody = (resp: response): option<readableStream> => Nullable.toOption(streamBodyRaw(resp))
@send external getReader: readableStream => readableStreamReader = "getReader"
// `value` is absent (not just empty) on the final `{done: true}` chunk in
// some engines, so it is an optional field, not a plain byteChunk.
type readResult = {done: bool, value?: byteChunk}
@send external read: readableStreamReader => promise<readResult> = "read"

type textDecoder
@new external makeTextDecoder: unit => textDecoder = "TextDecoder"
type decodeOptions = {stream: bool}
@send external decodeStream: (textDecoder, byteChunk, decodeOptions) => string = "decode"

// A delay as a promise, for the reconnect backoff — same
// `Promise.make`-over-`setTimeout` shape as src/web/Resize.res.
let delay = (ms: int): promise<unit> =>
  Promise.make((resolve, _reject) => setTimeout(() => resolve(), ms)->ignore)

// visibilitychange / online: so ScanApi can retry the moment the tab wakes
// up or the network comes back, instead of waiting out the backoff.
@get external documentVisibilityState: document => string = "visibilityState"
@send
external addDocumentListener: (document, string, unit => unit) => unit = "addEventListener"
type windowLike
@val external windowGlobal: windowLike = "window"
@send external addWindowListener: (windowLike, string, unit => unit) => unit = "addEventListener"

@send
external removeDocumentListener: (document, string, unit => unit) => unit = "removeEventListener"

@send external removeWindowListener: (windowLike, string, unit => unit) => unit = "removeEventListener"

// -- Geolocation (docs/spec-haul-map.md "The position") --------------------
// navigator.geolocation is undefined outside a secure context and on some
// older browsers, so it is read as nullable rather than assumed present.

type geolocationCoords = {latitude: float, longitude: float, accuracy: float}
type geolocationPosition = {coords: geolocationCoords}
type geolocationPositionError = {code: int}
type geolocationOptions = {enableHighAccuracy: bool, timeout: int, maximumAge: int}
type geolocation
@val @scope("navigator") external geolocation: Nullable.t<geolocation> = "geolocation"
@send
external getCurrentPosition: (
  geolocation,
  geolocationPosition => unit,
  geolocationPositionError => unit,
  geolocationOptions,
) => unit = "getCurrentPosition"
