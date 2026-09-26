# reflip upload progress: show the photo actually moving

Status: proposal, written 2026-09-26.

## Problem

Two places send a photo to the brain, and neither shows real progress:

1. The scan flow (`ScanApi.run`'s first POST, `docs/scan-ui.md` §2/§3), the
   only entry point today (`AppState.activeTab` defaults to `ScanTab`, and
   the old single-photo flow below is dead). While the photo is in flight,
   the scan card shows the headline "Sending photo" and the sub-line
   "Uploading N MB." (`ScanState.res` `headline`/`sub`, the `Sending`
   case). Neither changes until the brain answers. The scan card's own
   `scan-track` strip (`ScanView.res` line 221) is already on screen during
   `Sending`, but it fills by elapsed time out of the 3:00 limit
   (`pctOf(elapsed, limitMs)`), so at the start of a scan it just sits near
   empty — it carries no information about the upload itself.
2. Haul mode (`Api.postHaulScene`, `App.res`'s `uploadOne`). The haul view
   shows a tally of photos (`haul-tally`: queued, valuing, valued, failed,
   on-phone) and an offline banner once an upload has already failed and
   is waiting to retry. Nothing shows while an upload is actually going
   out — a photo sits in the "on phone" tile the whole time it uploads,
   with no visual difference between "about to start" and "90% sent".

Dwight often uses haul mode while walking a store on a phone signal that
is not great — that is exactly when a progress bar earns its keep, and
exactly when today's page gives him the least information: no motion, no
percentage, nothing to tell him an upload is stuck versus slow.

`Api.res`'s `postScene` and `App.res`'s `runPhotoFlow` (the original M0
flow, driving `AppState.status`/`Footer`) are unreferenced by the current
view — `App.make` only ever renders `ScanShell` or `HaulView`. They are
dead code today; see "Open questions".

## Research

Read 2026-09-26, to settle how to get real bytes-sent progress out of a
browser.

- `fetch()` has no built-in upload-progress event. The only way to see
  bytes leave the client is a streamed `ReadableStream` request body
  (`duplex: "half"`), counted with a `TransformStream` in front of it.
  [Jake Archibald, "Fetch streams are great, but not for measuring
  upload/download progress"](https://jakearchibald.com/2025/fetch-streams-not-for-progress/)
  (2025) explains this and still recommends `XMLHttpRequest` for real
  upload progress. He also notes streamed request bodies are Chrome-only
  today: "it isn't yet supported in either Firefox or Safari."
- [web-platform-tests/interop#1072](https://github.com/web-platform-tests/interop/issues/1072)
  confirms Safari (WebKit) throws on a streamed `fetch` request body
  ("ReadableStream uploading is not supported"), and that `ReadableStream`
  request-body support is only proposed for Interop 2026 — not shipped.
  reflip is a phone PWA and this repo's own `WebApi.res` header already
  tracks Safari/iOS Safari support closely (the `createImageBitmap`
  orientation note), so a Chrome-only technique is not an option here.
- `XMLHttpRequest`'s `upload` object and its `progress` event
  ([MDN, `XMLHttpRequestUpload`](https://developer.mozilla.org/en-US/docs/Web/API/XMLHttpRequestUpload))
  are Baseline "widely available", shipped since 2015, including Safari.
  `event.loaded` / `event.total` give real bytes sent so far, out of the
  request body's own size — for a `Blob` body, `lengthComputable` is true
  and `total` is the blob's byte size, no server change needed.

Conclusion: `XMLHttpRequest` is the only cross-browser way to get a real,
numeric upload percentage in this app. Fetch's `ReadableStream` request
body is out, both for the reason above and for a second reason specific
to the scan flow — see "Why the scan flow's own POST is harder", below.

## How it works

**Haul mode** gets a real, byte-accurate bar. `Api.postHaulScene` is a
plain POST-and-wait (JPEG body in, `{sceneId, duplicate}` JSON back) —
switching its transport from `fetch` to `XMLHttpRequest` costs nothing
else, and `xhr.upload.onprogress` gives an exact "N of M bytes sent" the
whole way. The haul view grows an "uploading" row, shown only while a
photo is actually `SendingNow`, styled like the existing budget row
(`App.res` lines ~995–1031, `.haul-budget-row`/`-track`/`-fill`): a label,
a percentage, and a filling track. It disappears the moment that upload
resolves (success or failure) — there is never more than one row, because
the queue already uploads one photo at a time.

**The scan flow** keeps showing "Uploading N MB." (unchanged), but the
`scan-track` strip switches to an indeterminate animation for the
`Sending` phase only, instead of filling by elapsed-time-of-3:00 (which is
close to meaningless in the first second or two of a scan anyway). The
moment the first SSE event lands (`photo-received`) the phase flips to
`Live` and the strip reverts to exactly what it does today — the
elapsed/3:00 fill. No wire change, no new model field: a pure view-level
switch on `model.phase == Sending`.

### Why the scan flow's own POST is harder

The scan flow's first POST does two jobs on one connection: it sends the
photo, and its response body is the live SSE event stream
(`ScanApi.run`'s `consume`, reading `WebApi.streamBody(resp)` off a
`fetch` `Response`). `XMLHttpRequest` cannot expose a streamed response
body as a `ReadableStream` — only `fetch` can. So this one request needs
`XMLHttpRequest`'s upload-progress event **and** `fetch`'s
`ReadableStream` response reading, and no single browser API gives both
at once. Splitting the two jobs onto two requests (upload, then open the
stream) is possible — see "Later" — but it is a real protocol change, not
a client-only tweak, so it does not belong in this MVP.

## Shape

No server change. Every part of this is client-side.

- `src/web/WebApi.res`: typed `XMLHttpRequest` bindings — `xhr`, `xhrUpload`,
  a `progressEvent` record (`loaded`, `total`, `lengthComputable`),
  `makeXhr`, `xhrOpen`, `xhrSetRequestHeader`, `xhrSend(xhr, blob)`,
  `xhrUpload(xhr): xhrUpload`, `addUploadProgressListener`, and
  `load`/`error`/`abort` listeners on the `xhr` itself. Same "no `%raw`,
  proper typed externals" rule this file's own header already states.
- `src/web/Api.res`: `postHaulScene` gains an `~onProgress: int => unit`
  parameter (bytes sent so far) and is rebuilt on `Promise.make` wrapping
  the XHR calls, in place of `WebApi.fetchBlob`. It keeps the same
  `result<(string, bool), string>` shape and the same error convention
  (`readErrorReason`'s `{"error": ...}` body, else the bare status code) —
  read from `xhr.status`/`xhr.responseText` instead of a `fetch`
  `Response`. `postScene` (the dead M0 path) is left alone unless it's
  deleted per "Open questions".
- `src/web/AppState.res`: `queueItem` gets `uploadedBytes: int` (0 by
  default). New msg `UploadProgress(clientId, int)`; `update` sets that
  one item's `uploadedBytes`. `UploadStarted` resets it to 0.
  `HaulUploadOk`/`HaulUploadFailed` need not touch it — the item is
  removed or requeued either way.
- `src/web/App.res`: `uploadOne` passes
  `bytes => dispatch(AppState.UploadProgress(item.clientId, bytes))` as
  `Api.postHaulScene`'s `~onProgress`.
- `src/web/HaulLayout.res`: a pure `uploadPct(sentBytes: int, totalBytes: int): float`,
  tested the way `budgetFillPct` already is.
  `App.res`'s `HaulView` renders the new row from the one queue item whose
  `status == SendingNow`, if any.
  `src/web/scan.css` gets the row's classes, copied structurally from
  `.haul-budget-row`/`-track`/`-fill`.
- `src/web/ScanView.res`: the `scan-track` block gets a class add,
  `scan-track-indeterminate`, applied only when `model.phase == ScanState.Sending`.
  `scan.css` gets that one class: a slid/pulsed background instead of a
  width driven by `pctOf`.
- Tests: `AppStateTest.res` gets a case for `UploadProgress`;
  `HaulLayoutTest.res` (or wherever `budgetFillPct` is tested today) gets
  one for `uploadPct`, including `total == 0` (a photo of 0 bytes should
  never happen, but the function must not divide by zero).

## MVP

In order:

1. `WebApi.res`'s XHR bindings.
2. `Api.postHaulScene` rebuilt on them, with `~onProgress`, and its own
   test double / fixture-mode path checked — `FIXTURES=1` haul uploads
   must keep working exactly as today.
3. `AppState.res` + `App.res` wiring, with a test for `UploadProgress`.
4. `HaulLayout.uploadPct` + the haul view's upload row + CSS, with a test.
5. `ScanView.res`'s indeterminate track class + CSS, no test needed (pure
   presentation, no new pure function).
6. Smoke test: extend `scripts/haul-smoke.mjs` to look for the upload row
   while a photo is `SendingNow` — on a fast loopback connection this may
   only be visible for a frame or two, so the check should assert the row
   exists in the DOM at some point during the run, not that a screenshot
   catches it mid-fill. Take one screenshot of it anyway, best-effort.
7. A PR with before/after screenshots or a short screen recording of a
   haul-mode upload on a throttled connection (Chrome DevTools network
   throttling is enough to make it visible), per the PR rules.

## Later

- Split the scan flow's own POST into two requests, so its "upload" gets a
  real byte-accurate bar too: `POST /api/scene/upload` (plain
  request/response, `XMLHttpRequest`, answers `{sceneId}` once the photo
  is fully received — mirroring `POST /api/hauls/:id/scenes`'s 202 shape),
  then `GET /api/scene/:id/events` (already exists, per
  `docs/scan-ui.md` §3) opens the SSE stream with no request body to
  track. `photo-received` already fires "before the Claude call starts"
  (`docs/scan-ui.md` §2), so the upload is already a distinct milestone
  server-side — the split follows a seam that is already there. This
  changes `StreamRoute.res` and the `isFirst` branch of `ScanApi.run`, so
  it is its own track, not part of this MVP.
- Delete `runPhotoFlow`, `Api.postScene`, and the `AppState.status`/
  `Footer` fields they alone drive, if nobody plans to bring the old M0
  view back (see Open questions) — then there is only one blob-upload
  convention in the codebase, not two.

## Risks

- On a fast connection (localhost, or the tailnet from a nearby room), a
  resized photo (typically a few hundred KB) uploads inside a single
  event-loop tick. The haul-mode bar may jump straight from 0% to 100%
  with no visible fill. That is fine — the bar's job is to show progress
  on a weak signal at a store, which is the case it was built for, not to
  animate on a fast network.
- Converting `postHaulScene` from `fetch` (a promise that rejects on a
  network error, read with `try`/`catch`) to `XMLHttpRequest` (which
  reports success/failure through `load`/`error`/`abort` events) changes
  the failure path's shape. Every one of those events needs an explicit
  listener that resolves or rejects the wrapping promise — a stray case
  left unhandled would hang forever instead of erroring, which is worse
  than today's behavior. Test the network-error and the abrupt-disconnect
  cases explicitly, not just the happy path.
- If a browser ever reports `lengthComputable: false` for a `Blob` body
  (not expected, per the research above, but not physically impossible),
  fall back to the same indeterminate treatment the scan flow uses for
  `Sending`, rather than showing a frozen or fake percentage.

## Open questions

- Is `runPhotoFlow`/`Api.postScene`/the old status-line `Footer` truly
  dead, or is there a plan to bring back a non-streaming single-photo
  view? If it is dead, deleting it (per "Later") should happen either
  just before or just after this spec, not left straddling both.
- Is the scan flow's own "Sending" phase actually slow enough on a real
  weak-signal store visit to justify the upload/events split in "Later"?
  Worth a measurement — Dwight logging the wall-clock time from tapping
  the camera to the first `photo-received` event on his own phone at a
  store with poor signal — before committing to that bigger change.
