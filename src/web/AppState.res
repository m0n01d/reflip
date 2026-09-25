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

type haulPhase =
  | NoHaul
  | Starting
  | Active(Types.haulStatus)
  | Finishing(Types.haulStatus) // Done tapped: draining the queue, then POST done
  | Finished(Types.haulStatus) // brain confirmed done; polling continues until emailedAt

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
  // The resized photo (the blob the page sends), as an object URL — set
  // once the resize finishes, cleared by a new photo. App.res revokes the
  // old URL as a side effect when it replaces this.
  photoUrl: option<string>,
  // The index into reply.items of the tapped card, or the item whose box
  // holds a tapped point on the photo. A new photo clears it.
  selected: option<int>,
  // The findId of the open gem card in haul mode, or None if every card is
  // closed. At most one card is open at a time (AppState.update, ToggleGem).
  openGem: option<string>,
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
  | ToggleGem(string) // a tap on a gem card's findId — same id closes, another switches, None opens

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
  photoUrl: None,
  selected: None,
  openGem: None,
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
  | StartHaul => {...model, haul: Starting, haulError: None}
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
    }
  | DoneSent(status) => {...model, haul: Finished(status), haulError: None}
  | DoneFailed(msg) => {...model, haulError: Some(msg)}
  | NewHaul => {
      ...model,
      haul: NoHaul,
      storeName: "",
      queue: [],
      uploadedCount: 0,
      pollCount: 0,
      haulError: None,
    }
  | SelectItem(i) => {...model, selected: Some(i)}
  | ToggleGem(findId) => {
      ...model,
      openGem: switch model.openGem {
      | Some(current) if current == findId => None
      | _ => Some(findId)
      },
    }
  }
