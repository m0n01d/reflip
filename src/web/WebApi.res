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
