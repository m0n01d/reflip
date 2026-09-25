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
