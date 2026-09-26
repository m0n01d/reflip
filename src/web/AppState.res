// Model / Msg / update for the phone page — pure, no DOM, no Node. Side
// effects (resize, fetch, IndexedDB, timers) run in App.res, which
// dispatches these msgs back in; update itself never touches the network,
// the canvas or idb-keyval. src/tests/AppStateTest.res exercises this
// module directly.
//
// Two flows share this one model: the original M0 single-photo flow (the
// `status`/`reply`/... fields, unchanged) and haul mode
// (docs/spec-haul-mode.md "Step 5: phone"), which adds `haul`, `storeName`
// and `queue`. The view picks one or the other based on `haul`.

type status = Idle | Resizing | Uploading | Waiting | ErrorStatus(string)

// A queue item's own state is spelled differently from `status` above
// (`SendingNow` not `Uploading`) so the two variant types never share a
// constructor name in this module.
type queueStatus = QueuedLocal | SendingNow | WaitingRetry

type queueItem = {
  clientId: string,
  blob: WebApi.blob,
  status: queueStatus,
  // Failed uploads so far for this item. Drives the retry backoff
  // (retryDelayMs below) and is never reset — a photo is never dropped.
  attempts: int,
}

type placeFix = {lat: float, lon: float, accuracyM: float, tookMs: option<float>}

// The seven states from docs/spec-haul-map.md "The position". Every
// constructor is prefixed `Place` so none collides with a msg name below —
// AppState.update switches on both types together.
type placeState =
  | PlaceNotAsked
  | PlaceAsking
  | PlaceSending(placeFix)
  | PlaceNotSent(placeFix)
  | PlaceSaved(option<Types.place>, option<float>)
  | PlaceDenied
  | PlaceFailed

type haulPhase =
  | NoHaul
  | Starting
  | Active(Types.haulStatus)
  | Finishing(Types.haulStatus) // Done tapped: draining the queue, then POST done
  | Finished(Types.haulStatus) // brain confirmed done; polling continues until emailedAt

// The Scan/Haul chrome switch (docs/design/scan-ui/Main.dc.html) — display
// only, independent of haulPhase above. NoHaul + HaulTab shows the existing
// haul-start entry form; NoHaul + ScanTab shows the restyled scan Ready
// screen. Any other haulPhase always shows HaulView regardless of this.
type tab = ScanTab | HaulTab

type model = {
  selectedModel: Shared.model,
  longEdge: int,
  status: status,
  reply: option<Types.sceneReply>,
  uploadBytes: option<int>,
  resizeMs: option<float>,
  rttMs: option<float>,
  // -- haul mode ----------------------------------------------------------
  haul: haulPhase,
  storeName: string,
  queue: array<queueItem>,
  uploadedCount: int,
  pollCount: int,
  haulError: option<string>,
  // How many Done attempts have failed since the last DoneTapped, DoneSent
  // or NewHaul (decision 10). App.res's retry effect reads this to back
  // off per retryDelayMs; DoneFailed increments it.
  doneAttempts: int,
  // The resized photo (the blob the page sends), as an object URL — set
  // once the resize finishes, cleared by a new photo. App.res revokes the
  // old URL as a side effect when it replaces this.
  photoUrl: option<string>,
  // The index into reply.items of the tapped card, or the item whose box
  // holds a tapped point on the photo. A new photo clears it.
  selected: option<int>,
  // The new streaming scan flow (docs/scan-ui.md): ScanState owns its own
  // model/msg/update, folded in here through the Scan msg below.
  scan: ScanState.model,
  // Scan/Haul chrome switch + the Settings sheet (Model, Photo size) — both
  // display-only, read by ScanShell.res.
  activeTab: tab,
  settingsOpen: bool,
  // The findId of the open gem card in haul mode, or None if every card is
  // closed. At most one card is open at a time (AppState.update, ToggleGem).
  openGem: option<string>,
  // The device position for this haul (docs/spec-haul-map.md "The
  // position"). See placeState above for the seven states.
  place: placeState,
}

type msg =
  // M0 (unchanged)
  | SetModel(Shared.model)
  | SetLongEdge(int)
  | StartPhoto
  | ResizeOk(float, int)
  | ResizeErr(string)
  | PhotoUrlReady(string)
  | UploadOk(Types.sceneReply, float)
  | UploadErr(string)
  | RttSent
  | RttErr(string)
  // Haul mode
  | SetStoreName(string)
  | StartHaul
  | HaulStarted(Types.haulStatus) // a fresh POST /api/hauls, or a restored GET
  | HaulStartFailed(string)
  | PhotosPicked(int) // "Add photos" picked N files, before any is resized
  | PhotoQueued(string, WebApi.blob) // one photo resized and written to IndexedDB
  | PhotoQueueErr(string)
  | QueueRestored(array<(string, WebApi.blob)>) // read back from IndexedDB on load
  | UploadStarted(string)
  | HaulUploadOk(string, string) // clientId, sceneId
  | HaulUploadFailed(string, string) // clientId, error
  | RetryDue(string) // the backoff timer for this clientId fired
  | PollTick
  | StatusLoaded(Types.haulStatus)
  | StatusLoadFailed(string)
  | DoneTapped
  | DoneSent(Types.haulStatus)
  | DoneFailed(string)
  | NewHaul // start over once the haul is emailed
  | SelectItem(int)
  | Scan(ScanState.msg)
  | SetActiveTab(tab)
  | SetSettingsOpen(bool)
  | ToggleGem(string) // a tap on a gem card's findId — same id closes, another switches, None opens
  // The position (docs/spec-haul-map.md "The position"). PlaceAskAgain is
  // the Try again tap; StartHaul itself sets PlaceAsking directly, with no
  // msg of its own.
  | PlaceAskAgain
  | PlaceFixed(placeFix)
  | PlaceGeoDenied
  | PlaceUnavailable
  | PlaceSent(option<Types.place>)
  | PlaceSendFailed
  | PlaceRejected

let initialModel: model = {
  selectedModel: Shared.defaultModel,
  longEdge: 1568,
  status: Idle,
  reply: None,
  uploadBytes: None,
  resizeMs: None,
  rttMs: None,
  haul: NoHaul,
  storeName: "",
  queue: [],
  uploadedCount: 0,
  pollCount: 0,
  haulError: None,
  doneAttempts: 0,
  photoUrl: None,
  selected: None,
  scan: ScanState.initialModel,
  activeTab: ScanTab,
  settingsOpen: false,
  openGem: None,
  place: PlaceNotAsked,
}

// -- IndexedDB key layout (docs/spec-haul-mode.md "Step 5: phone") --------
// "q|<haulId>|<clientId>" -> the resized JPEG blob. "haul" -> the current
// haul id, as a plain string. Both pure here; App.res does the actual
// idb-keyval calls.
let currentHaulKey = "haul"

let queueKey = (haulId: string, clientId: string): string => "q|" ++ haulId ++ "|" ++ clientId

let parseQueueKey = (key: string): option<(string, string)> =>
  switch String.split(key, "|") {
  | [prefix, haulId, clientId] if prefix == "q" => Some((haulId, clientId))
  | _ => None
  }

let placeKey = (haulId: string): string => "place|" ++ haulId

// Distinct from queueKey's 3-part "q|<haulId>|<clientId>" shape, so a
// place key never matches parseQueueKey and vice versa (AppStateTest checks
// this both ways).
let parsePlaceKey = (key: string): option<string> =>
  switch String.split(key, "|") {
  | [prefix, haulId] if prefix == "place" => Some(haulId)
  | _ => None
  }

// The exact POST body for /api/hauls/:id/place — always source "gps", the
// only source the page itself ever produces (a "pin" place is set some
// other way, out of scope for this spike). This same string is the value
// written to the place|<haulId> outbox entry.
let encodePlaceBody = (fix: placeFix): string =>
  JSON.stringify(
    Json.obj([
      ("lat", Json.num(fix.lat)),
      ("lon", Json.num(fix.lon)),
      ("accuracyM", Json.num(fix.accuracyM)),
      ("source", Json.str("gps")),
    ]),
  )

// The inverse read, for the outbox: tookMs is never stored (it is only
// ever known at the moment the fix was measured), so a decoded body always
// gives None there. Bad JSON, or a body missing lat/lon/accuracyM, is None.
let decodePlaceBody = (body: string): option<placeFix> =>
  switch JSON.parseOrThrow(body) {
  | json =>
    switch (
      Json.floatField(json, "lat"),
      Json.floatField(json, "lon"),
      Json.floatField(json, "accuracyM"),
    ) {
    | (Some(lat), Some(lon), Some(accuracyM)) => Some({lat, lon, accuracyM, tookMs: None})
    | _ => None
    }
  | exception JsExn(_) => None
  }

// The fix carried by a placeState, when it has one — used by placeLine (the
// "saved locally" case) and by update (PlaceSent carries the fix already in
// flight forward into PlaceSaved).
let fixOfPlaceState = (state: placeState): option<placeFix> =>
  switch state {
  | PlaceSending(fix) | PlaceNotSent(fix) => Some(fix)
  | PlaceSaved(_, _) | PlaceNotAsked | PlaceAsking | PlaceDenied | PlaceFailed => None
  }

// "±N m", N the accuracy rounded to the nearest metre.
let placeAccuracyText = (accuracyM: float): string =>
  "±" ++ Int.toString(Float.toInt(Math.round(accuracyM))) ++ " m"

// " · T s", T the elapsed time in seconds to one decimal place.
let placeTookText = (tookMs: float): string =>
  " · " ++ Float.toFixed(tookMs /. 1000.0, ~digits=1) ++ " s"

// The haul view's one-line place status, and whether to show a "Try
// again" control next to it. First match wins, per
// docs/spec-haul-map.md "The position":
// 1. the brain already has a place -> "Place saved" (or, for a pin,
//    "Place set by hand"), with a " · T s" suffix when this page is the
//    one that just saved it (PlaceSaved with a tookMs).
// 2. no brain place yet, but this page saved one locally -> the same text.
// 3..7: asking / sending / not sent / denied / failed-or-not-asked.
// placeLine's result: the haul view's one-line status text, and whether to
// show a Try again control next to it.
type placeLineText = {text: string, tryAgain: bool}

// The saved-place text for a brain place, shared by both the "brain has it"
// branch and the "saved locally" PlaceSaved(Some(p), _) branch below.
let placeSavedText = (p: Types.place, tookMs: option<float>): string => {
  let took = tookMs->Option.mapOr("", placeTookText)
  switch p.source {
  | Pin => "Place set by hand"
  | Gps => "Place saved · " ++ p.accuracyM->Option.mapOr("", placeAccuracyText) ++ took
  }
}

let placeLine = (place: placeState, brain: option<Types.place>): option<placeLineText> =>
  switch brain {
  | Some(p) =>
    let took = switch place {
    | PlaceSaved(_, tookMs) => tookMs
    | _ => None
    }
    Some({text: placeSavedText(p, took), tryAgain: false})
  | None =>
    switch place {
    | PlaceSaved(Some(p), tookMs) => Some({text: placeSavedText(p, tookMs), tryAgain: false})
    | PlaceSaved(None, tookMs) =>
      Some({text: "Place saved" ++ tookMs->Option.mapOr("", placeTookText), tryAgain: false})
    | PlaceAsking => Some({text: "Finding place…", tryAgain: false})
    | PlaceSending(_) => Some({text: "Saving place…", tryAgain: false})
    | PlaceNotSent(_) => Some({text: "Place not sent yet", tryAgain: true})
    | PlaceDenied => Some({text: "No place", tryAgain: false})
    | PlaceFailed | PlaceNotAsked => Some({text: "No place yet", tryAgain: true})
    }
  }

// The haul payload, regardless of which phase is holding it — lets the
// poller and the view read "the current status" without a phase match.
let haulStatusOf = (phase: haulPhase): option<Types.haulStatus> =>
  switch phase {
  | NoHaul | Starting => None
  | Active(status) | Finishing(status) | Finished(status) => Some(status)
  }

// 5 s, 15 s, then 60 s forever. A photo is never dropped, so there is no
// final give-up tier.
// The "uploaded" chip. The brain's scene count survives a reload, but it
// lags a new upload by up to one poll, so the chip shows the larger count.
let uploadedShown = (model: model, counts: Types.haulCounts): int =>
  Math.Int.max(model.uploadedCount, counts.queued + counts.running + counts.valued + counts.failed)

let retryDelayMs = (attempts: int): int =>
  switch attempts {
  | 1 => 5000
  | 2 => 15000
  | _ => 60000
  }

let updateQueueItem = (
  queue: array<queueItem>,
  clientId: string,
  f: queueItem => queueItem,
): array<queueItem> => Array.map(queue, item => item.clientId == clientId ? f(item) : item)

let removeQueueItem = (queue: array<queueItem>, clientId: string): array<queueItem> =>
  Array.filter(queue, item => item.clientId != clientId)

let addQueueItem = (queue: array<queueItem>, clientId: string, blob: WebApi.blob): array<
  queueItem,
> =>
  switch Array.find(queue, item => item.clientId == clientId) {
  | Some(_) => queue // already queued (a restore or a duplicate dispatch) — no-op
  | None => Array.concat(queue, [{clientId, blob, status: QueuedLocal, attempts: 0}])
  }

let update = (model: model, msg: msg): model =>
  switch msg {
  | SetModel(m) => {...model, selectedModel: m}
  | SetLongEdge(e) => {...model, longEdge: e}
  | StartPhoto => {
      ...model,
      status: Resizing,
      reply: None,
      uploadBytes: None,
      resizeMs: None,
      rttMs: None,
      photoUrl: None,
      selected: None,
    }
  | ResizeOk(resizeMs, uploadBytes) => {
      ...model,
      status: Uploading,
      resizeMs: Some(resizeMs),
      uploadBytes: Some(uploadBytes),
    }
  | ResizeErr(errMsg) => {...model, status: ErrorStatus(errMsg)}
  | PhotoUrlReady(url) => {...model, photoUrl: Some(url)}
  | UploadOk(reply, rttMs) => {...model, status: Waiting, reply: Some(reply), rttMs: Some(rttMs)}
  | UploadErr(errMsg) => {...model, status: ErrorStatus(errMsg)}
  | RttSent => {...model, status: Idle}
  | RttErr(errMsg) => {...model, status: ErrorStatus(errMsg)}

  | SetStoreName(name) => {...model, storeName: name}
  | StartHaul => {...model, haul: Starting, haulError: None, place: PlaceAsking}
  | HaulStarted(status) => {...model, haul: Active(status), haulError: None}
  | HaulStartFailed(msg) => {...model, haul: NoHaul, haulError: Some(msg)}
  | PhotosPicked(_) => model
  | PhotoQueued(clientId, blob) => {...model, queue: addQueueItem(model.queue, clientId, blob)}
  | PhotoQueueErr(msg) => {...model, haulError: Some(msg)}
  | QueueRestored(items) => {
      ...model,
      queue: Array.reduce(items, model.queue, (queue, (clientId, blob)) =>
        addQueueItem(queue, clientId, blob)
      ),
    }
  | UploadStarted(clientId) => {
      ...model,
      queue: updateQueueItem(model.queue, clientId, item => {...item, status: SendingNow}),
    }
  | HaulUploadOk(clientId, _sceneId) => {
      ...model,
      queue: removeQueueItem(model.queue, clientId),
      uploadedCount: model.uploadedCount + 1,
    }
  | HaulUploadFailed(clientId, errMsg) => {
      ...model,
      queue: updateQueueItem(model.queue, clientId, item => {
        ...item,
        status: WaitingRetry,
        attempts: item.attempts + 1,
      }),
      haulError: Some(errMsg),
    }
  | RetryDue(clientId) => {
      ...model,
      queue: updateQueueItem(model.queue, clientId, item => {...item, status: QueuedLocal}),
    }
  | PollTick => {...model, pollCount: model.pollCount + 1}
  | StatusLoaded(newStatus) => {
      ...model,
      haul: switch model.haul {
      | Active(_) => Active(newStatus)
      | Finishing(_) => Finishing(newStatus)
      | Finished(_) => Finished(newStatus)
      | other => other
      },
    }
  | StatusLoadFailed(msg) => {...model, haulError: Some(msg)}
  | DoneTapped => {
      ...model,
      haul: switch model.haul {
      | Active(status) | Finishing(status) => Finishing(status)
      | other => other
      },
      haulError: None,
      doneAttempts: 0,
    }
  | DoneSent(status) => {...model, haul: Finished(status), haulError: None, doneAttempts: 0}
  | DoneFailed(msg) => {...model, haulError: Some(msg), doneAttempts: model.doneAttempts + 1}
  | NewHaul => {
      ...model,
      haul: NoHaul,
      storeName: "",
      queue: [],
      uploadedCount: 0,
      pollCount: 0,
      haulError: None,
      doneAttempts: 0,
      place: PlaceNotAsked,
    }
  | SelectItem(i) => {...model, selected: Some(i)}
  | Scan(scanMsg) => {...model, scan: ScanState.update(model.scan, scanMsg)}
  | SetActiveTab(t) => {...model, activeTab: t}
  | SetSettingsOpen(open_) => {...model, settingsOpen: open_}
  | ToggleGem(findId) => {
      ...model,
      openGem: switch model.openGem {
      | Some(current) if current == findId => None
      | _ => Some(findId)
      },
    }
  | PlaceAskAgain => {...model, place: PlaceAsking}
  | PlaceFixed(fix) => {...model, place: PlaceSending(fix)}
  | PlaceGeoDenied => {...model, place: PlaceDenied}
  | PlaceUnavailable => {...model, place: PlaceFailed}
  | PlaceSent(place) => {
      ...model,
      place: PlaceSaved(place, fixOfPlaceState(model.place)->Option.flatMap(fix => fix.tookMs)),
    }
  | PlaceSendFailed => {
      ...model,
      place: switch model.place {
      | PlaceSending(fix) => PlaceNotSent(fix)
      | other => other
      },
    }
  | PlaceRejected => {...model, place: PlaceFailed}
  }
