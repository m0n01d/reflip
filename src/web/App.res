// The phone page. Two flows share one page: the original M0 single-photo
// flow (model picker, long-edge picker, take-photo button, status line,
// photo with item boxes, item list, footer) and haul mode
// (docs/spec-haul-mode.md "Step 5: phone"), which replaces that view once a
// haul is started. TEA via useReducer — this file holds the view and the
// effect orchestrator; AppState.res holds the pure model/msg/update.
// BoxLayout.res holds the pure crop and hit-test math this file turns into
// styles and taps.

@send external toFixed: (float, int) => string = "toFixed"

let fmtUsd = (n: float): string => "$" ++ toFixed(n, 2)
let fmtUsd4 = (n: float): string => "$" ++ toFixed(n, 4)
let fmtPct = (n: float): string => toFixed(n *. 100.0, 0) ++ "%"
let fmtMs = (n: float): string => toFixed(n, 0) ++ " ms"
let fmtOptMs = (n: option<float>): string =>
  switch n {
  | Some(ms) => fmtMs(ms)
  | None => "—"
  }

// left/top/width/height of a box as CSS percent, against the photo's own
// pixel size — the box overlay on the photo and the crop math both start
// from the same imageWidth/imageHeight the reply carries.
let pct = (n: int, total: int): string => toFixed(Int.toFloat(n) /. Int.toFloat(total) *. 100.0, 2) ++ "%"

// The side-effect edge: called from the file input's onChange, never from
// update/view. Dispatches a msg after each step so `update` stays pure.
// The object URL for the resized photo is created here too — it is a side
// effect (WebApi.createObjectURL), not something `update` could do.
let runPhotoFlow = async (
  dispatch: AppState.msg => unit,
  modelId: string,
  longEdge: int,
  file: WebApi.blob,
) => {
  dispatch(AppState.StartPhoto)
  switch await Resize.resizeToJpeg(file, longEdge) {
  | Error(msg) => dispatch(AppState.ResizeErr(msg))
  | Ok((blob, resizeMs)) =>
    let uploadBytes = WebApi.blobSize(blob)
    dispatch(AppState.ResizeOk(resizeMs, uploadBytes))
    dispatch(AppState.PhotoUrlReady(WebApi.createObjectURL(blob)))
    switch await Api.postScene(modelId, blob) {
    | Error(msg) => dispatch(AppState.UploadErr(msg))
    | Ok((reply, rttMs)) =>
      dispatch(AppState.UploadOk(reply, rttMs))
      switch await Api.postRtt(reply.sceneId, rttMs, resizeMs) {
      | Error(msg) => dispatch(AppState.RttErr(msg))
      | Ok() => dispatch(AppState.RttSent)
      }
    }
  }
}

// The side-effect edge for the new streaming scan flow (docs/scan-ui.md):
// resize, then hand the blob straight to ScanApi.run, which owns the POST,
// the SSE read, the heartbeat watchdog and the reconnect backoff. Reports
// the handle and the object URL back through the two setters, so Stop and
// New scan's own edge effects (in make, below) can reach them.
let runScanFlow = async (
  dispatch: AppState.msg => unit,
  setHandle: ScanApi.handle => unit,
  setPhotoUrl: string => unit,
  scanModel: Shared.model,
  longEdge: int,
  file: WebApi.blob,
) =>
  switch await Resize.resizeToJpeg(file, longEdge) {
  | Error(msg) => dispatch(AppState.ResizeErr(msg))
  | Ok((blob, _resizeMs)) =>
    let photoUrl = WebApi.createObjectURL(blob)
    setPhotoUrl(photoUrl)
    dispatch(
      AppState.Scan(
        ScanState.PhotoPicked({model: scanModel, photoUrl, bytes: WebApi.blobSize(blob)}),
      ),
    )
    setHandle(ScanApi.run(~model=scanModel, ~blob, ~dispatch=msg => dispatch(AppState.Scan(msg))))
  }

let statusText = (status: AppState.status): string =>
  switch status {
  | Idle => ""
  | Resizing => "resizing"
  | Uploading => "uploading"
  | Waiting => "waiting"
  | ErrorStatus(msg) => msg
  }

// A card or the photo scrolling its counterpart into view on selection —
// the DOM lookup by id is the simplest typed way to reach a node that
// isn't the click target itself. See WebApi.res's getElementById/
// scrollIntoView.
let scrollIntoViewById = (id: string): unit =>
  switch WebApi.getElementById(WebApi.document, id)->Nullable.toOption {
  | Some(el) => WebApi.scrollIntoView(el, {WebApi.behavior: "smooth", block: "nearest"})
  | None => ()
  }

let itemCardId = (i: int): string => "item-card-" ++ Int.toString(i)
let photoWrapId = "reflip-photo"

module EbayBlock = {
  @react.component
  let make = (~ebay: option<Types.ebayStats>) =>
    switch ebay {
    | Some(stats) =>
      <div className="ebay">
        <div className="ebay-label"> {React.string("active asking prices, not sold")} </div>
        <div className="ebay-range">
          {React.string(
            "n=" ++
            Int.toString(stats.count) ++
            "  " ++
            fmtUsd(stats.minUsd) ++
            " – " ++
            fmtUsd(stats.maxUsd) ++
            " (median " ++
            fmtUsd(stats.medianUsd) ++ ")",
          )}
        </div>
      </div>
    | None => <div className="ebay ebay-missing"> {React.string("no eBay stats")} </div>
  }
}

// The photo, shown once at the top at the width of the screen, with a
// box drawn over it in percent (docs/spec-item-boxes.md "How it works" #3).
// A tap anywhere on the photo runs the hit test. Takes the photo's own
// pixel size directly (not a full sceneReply) so the haul view's open gem
// card can reuse it too — it has a box and a size, but no sceneReply.
module PhotoView = {
  @react.component
    let make = (
      ~photoUrl: string,
      ~imageWidth: option<int>,
      ~imageHeight: option<int>,
      ~selectedBox: option<Types.box>,
      ~onPhotoTap: ReactEvent.Mouse.t => unit,
    ) =>
      <div id={photoWrapId} className="photo-wrap">
        <img className="photo-img" src={photoUrl} onClick={onPhotoTap} />
        {switch (selectedBox, imageWidth, imageHeight) {
        | (Some(b), Some(imageWidth), Some(imageHeight)) =>
          <div
            className="photo-box"
            style={{
              JsxDOMStyle.left: pct(b.x1, imageWidth),
              top: pct(b.y1, imageHeight),
              width: pct(b.x2 - b.x1, imageWidth),
              height: pct(b.y2 - b.y1, imageHeight),
            }}
          />
        | _ => React.null
        }}
      </div>
}

// The crop of one item's box out of its photo: a 10% margin around the box,
// scaled to fit a small fixed size (BoxLayout.cropOf). Shared by ItemCard
// (the scene view) and GemCard (the haul view), so both render the same
// crop the same way. No box, or a missing photo size, shows "no box".
module CropView = {
  @react.component
  let make = (
    ~box: option<Types.box>,
    ~photoUrl: string,
    ~imageWidth: option<int>,
    ~imageHeight: option<int>,
  ) =>
    switch (box, imageWidth, imageHeight) {
    | (Some(box), Some(imageWidth), Some(imageHeight)) =>
      let crop = BoxLayout.cropOf(box, imageWidth, imageHeight)
      <div
        className="item-crop"
        style={{
          JsxDOMStyle.width: toFixed(crop.divWidth, 1) ++ "px",
          height: toFixed(crop.divHeight, 1) ++ "px",
          backgroundImage: "url(" ++ photoUrl ++ ")",
          backgroundSize: toFixed(crop.bgWidth, 1) ++ "px " ++ toFixed(crop.bgHeight, 1) ++ "px",
          backgroundPosition: "-" ++
          toFixed(crop.bgX, 1) ++
          "px -" ++
          toFixed(crop.bgY, 1) ++ "px",
        }}
      />
    | _ => <div className="item-crop item-crop-missing"> {React.string("no box")} </div>
    }
}

module ItemCard = {
  @react.component
  let make = (
    ~item: Types.replyItem,
    ~index: int,
    ~photoUrl: string,
    ~imageWidth: int,
    ~imageHeight: int,
    ~selected: bool,
    ~onSelect: int => unit,
  ) =>
    <li
      id={itemCardId(index)}
      className={"item" ++ (selected ? " item-selected" : "")}
      onClick={_ => onSelect(index)}>
      <div className="item-top">
        <CropView
          box={item.box}
          photoUrl
          imageWidth={Some(imageWidth)}
          imageHeight={Some(imageHeight)}
        />
        <div className="item-info">
          <div className="item-name">
            {React.string(item.name)}
            {item.size == "" ? React.null : React.string(" (" ++ item.size ++ ")")}
          </div>
          <div className="item-range">
            {React.string(fmtUsd(item.estimateLowUsd) ++ " – " ++ fmtUsd(item.estimateHighUsd))}
          </div>
          <div className="item-confidence">
            {React.string("confidence " ++ fmtPct(item.confidence))}
          </div>
          <div className="item-basis"> {React.string(item.basis)} </div>
        </div>
      </div>
      {item.sources->Array.length > 0
        ? <ul className="item-sources">
            {item.sources
            ->Array.mapWithIndex((src, i) =>
              <li key={Int.toString(i)}>
                <a href={src} target="_blank" rel="noreferrer"> {React.string(src)} </a>
              </li>
            )
            ->React.array}
          </ul>
        : React.null}
      <EbayBlock ebay={item.ebay} />
      <a className="sold-link" href={item.soldSearchUrl} target="_blank" rel="noreferrer">
        {React.string("Sold listings")}
      </a>
    </li>
}

module Footer = {
  @react.component
  let make = (~model: AppState.model, ~reply: Types.sceneReply) =>
    <footer className="footer">
      <div> {React.string("model: " ++ reply.model)} </div>
      <div> {React.string("fixture: " ++ (reply.fixture ? "yes" : "no"))} </div>
      <div>
        {React.string(
          "upload: " ++
          switch model.uploadBytes {
          | Some(b) => toFixed(Int.toFloat(b) /. 1024.0, 1) ++ " KB"
          | None => "—"
          },
        )}
      </div>
      <div> {React.string("resize: " ++ fmtOptMs(model.resizeMs))} </div>
      <div> {React.string("round trip: " ++ fmtOptMs(model.rttMs))} </div>
      <div> {React.string("server: " ++ fmtMs(reply.timing.serverMs))} </div>
      <div> {React.string("Claude: " ++ fmtMs(reply.timing.claudeMs))} </div>
      <div> {React.string("eBay: " ++ fmtMs(reply.timing.ebayMs))} </div>
      <div> {React.string("cost: " ++ fmtUsd4(reply.cost.usd))} </div>
      <div>
        {React.string(
          "tokens in/out: " ++
          Int.toString(reply.cost.inputTokens) ++
          " / " ++
          Int.toString(reply.cost.outputTokens),
        )}
      </div>
      <div> {React.string("web searches: " ++ Int.toString(reply.cost.webSearches))} </div>
      <div>
        {React.string("Quarter: " ++ (reply.quarterSeen ? "seen" : "not seen"))}
      </div>
      {switch reply.ebayNote {
      | Some(note) => <div className="ebay-note"> {React.string(note)} </div>
      | None => React.null
      }}
    </footer>
}

// -- Haul mode (docs/spec-haul-mode.md "Step 5: phone") ---------------------
// Every function below is a side-effect edge, same shape as runPhotoFlow
// above: it dispatches a msg at each step and never returns state directly.

// No long-edge picker in haul mode (the plan keeps that view plain) — this
// matches M0's own default.
let haulLongEdge = 1568

let queuePhoto = async (dispatch: AppState.msg => unit, haulId: string, file: WebApi.blob) =>
  switch await Resize.resizeToJpeg(file, haulLongEdge) {
  | Error(msg) => dispatch(AppState.PhotoQueueErr(msg))
  | Ok((blob, _resizeMs)) =>
    let clientId = WebApi.randomUUID()
    await WebApi.idbSetBlob(AppState.queueKey(haulId, clientId), blob)
    dispatch(AppState.PhotoQueued(clientId, blob))
  }

let queuePhotos = async (
  dispatch: AppState.msg => unit,
  haulId: string,
  files: array<WebApi.blob>,
) => {
  dispatch(AppState.PhotosPicked(Array.length(files)))
  let _ = await Promise.all(Array.map(files, file => queuePhoto(dispatch, haulId, file)))
}

let startHaul = async (dispatch: AppState.msg => unit, storeName: string) => {
  dispatch(AppState.StartHaul)
  switch await Api.postHaul(storeName) {
  | Ok(status) =>
    await WebApi.idbSetString(AppState.currentHaulKey, status.haulId)
    dispatch(AppState.HaulStarted(status))
  | Error(msg) => dispatch(AppState.HaulStartFailed(msg))
  }
}

// Re-reads every queued-but-unsent photo for one haul back out of
// IndexedDB. Called once, right after a haul is restored on load.
let restoreQueueFor = async (dispatch: AppState.msg => unit, haulId: string) => {
  let keys = await WebApi.idbKeysUnknown()
  let keyTexts = await Promise.all(Array.map(keys, WebApi.unknownToText))
  let matches =
    keyTexts
    ->Array.filterMap(AppState.parseQueueKey)
    ->Array.filter(((kHaulId, _clientId)) => kHaulId == haulId)
  let items = await Promise.all(
    Array.map(matches, async ((kHaulId, clientId)) =>
      switch (await WebApi.idbGetUnknown(AppState.queueKey(kHaulId, clientId)))->Nullable.toOption {
      | Some(v) =>
        let blob = await WebApi.unknownToBlob(v)
        Some((clientId, blob))
      | None => None
      }
    ),
  )
  dispatch(AppState.QueueRestored(items->Array.filterMap(x => x)))
}

// On load: is there a haul in progress? IndexedDB survives a reload, so a
// haul the page never got to close keeps its queue.
let restoreHaul = async (dispatch: AppState.msg => unit) =>
  switch (await WebApi.idbGetUnknown(AppState.currentHaulKey))->Nullable.toOption {
  | None => ()
  | Some(v) =>
    let haulId = await WebApi.unknownToText(v)
    switch await Api.getHaulStatus(haulId) {
    | Ok(status) =>
      dispatch(AppState.HaulStarted(status))
      await restoreQueueFor(dispatch, haulId)
    | Error(msg) =>
      await WebApi.idbDel(AppState.currentHaulKey)
      dispatch(AppState.HaulStartFailed(msg))
    }
  }

// One upload at a time, per the plan. On success the IndexedDB entry is
// deleted; on failure the photo stays queued and a backoff timer retries
// it — it is never dropped.
let uploadOne = async (dispatch: AppState.msg => unit, haulId: string, item: AppState.queueItem) => {
  dispatch(AppState.UploadStarted(item.clientId))
  switch await Api.postHaulScene(haulId, item.clientId, item.blob) {
  | Ok((sceneId, _duplicate)) =>
    await WebApi.idbDel(AppState.queueKey(haulId, item.clientId))
    dispatch(AppState.HaulUploadOk(item.clientId, sceneId))
  | Error(errMsg) =>
    let delay = AppState.retryDelayMs(item.attempts + 1)
    dispatch(AppState.HaulUploadFailed(item.clientId, errMsg))
    WebApi.setTimeout(() => dispatch(AppState.RetryDue(item.clientId)), delay)->ignore
  }
}

let pollHaul = async (dispatch: AppState.msg => unit, haulId: string) => {
  dispatch(AppState.PollTick)
  switch await Api.getHaulStatus(haulId) {
  | Ok(status) => dispatch(AppState.StatusLoaded(status))
  | Error(msg) => dispatch(AppState.StatusLoadFailed(msg))
  }
}

let finishHaul = async (dispatch: AppState.msg => unit, haulId: string) =>
  switch await Api.postHaulDone(haulId) {
  | Ok(status) => dispatch(AppState.DoneSent(status))
  | Error(msg) => dispatch(AppState.DoneFailed(msg))
  }

// A gem card: a crop next to its info, same layout as ItemCard's scene
// view. A tap on the card opens or closes its full photo underneath, with
// its box drawn on it (PhotoView, reused from the scene view) — a tap on
// the sold link must not also toggle the card, so that link stops the
// click from bubbling up to the card's own onClick.
module GemCard = {
  @react.component
  let make = (~gem: Types.haulGem, ~isOpen: bool, ~onToggle: string => unit) =>
    <li className="item" onClick={_ => onToggle(gem.findId)}>
      <div className="item-top">
        <CropView
          box={gem.box}
          photoUrl={Api.scenePhotoUrl(gem.sceneId)}
          imageWidth={gem.imageWidth}
          imageHeight={gem.imageHeight}
        />
        <div className="item-info">
          <div className="item-name">
            {React.string(gem.name)}
            {gem.size == "" ? React.null : React.string(" (" ++ gem.size ++ ")")}
          </div>
          <div className="item-range">
            {React.string(fmtUsd(gem.estimateLowUsd) ++ " – " ++ fmtUsd(gem.estimateHighUsd))}
          </div>
          {switch gem.where {
          | Some(w) => <div className="item-basis"> {React.string(w)} </div>
          | None => React.null
          }}
          <div className="item-confidence">
            {React.string("confidence " ++ fmtPct(gem.confidence))}
          </div>
        </div>
      </div>
      <EbayBlock ebay={gem.ebay} />
      <a
        className="sold-link"
        href={gem.soldSearchUrl}
        target="_blank"
        rel="noreferrer"
        onClick={ReactEvent.Mouse.stopPropagation}>
        {React.string("Sold listings")}
      </a>
      {isOpen
        ? <PhotoView
            photoUrl={Api.scenePhotoUrl(gem.sceneId)}
            imageWidth={gem.imageWidth}
            imageHeight={gem.imageHeight}
            selectedBox={gem.box}
            onPhotoTap={_ => ()}
          />
        : React.null}
    </li>
}

module HaulView = {
  @react.component
  let make = (
    ~model: AppState.model,
    ~phase: AppState.haulPhase,
    ~status: Types.haulStatus,
    ~onTakePhoto: ReactEvent.Form.t => unit,
    ~onAddPhotos: ReactEvent.Form.t => unit,
    ~onDone: ReactEvent.Mouse.t => unit,
    ~onNewHaul: ReactEvent.Mouse.t => unit,
    ~onToggleGem: string => unit,
  ) => {
    let onPhone = Array.length(model.queue)
    <div className="haul-view">
      <h2> {React.string(status.name->Option.getOr("Haul"))} </h2>
      <div className="counts">
        <div className="count">
          {React.string("on phone " ++ Int.toString(onPhone))}
        </div>
        <div className="count">
          {React.string("uploaded " ++ Int.toString(AppState.uploadedShown(model, status.counts)))}
        </div>
        <div className="count">
          {React.string("valued " ++ Int.toString(status.counts.valued))}
        </div>
        <div className="count">
          {React.string("failed " ++ Int.toString(status.counts.failed))}
        </div>
      </div>
      <div className="cost-line">
        {React.string(fmtUsd(status.costUsd) ++ " of " ++ fmtUsd(status.maxUsd) ++ " budget")}
      </div>
      {switch status.stopReason {
      | Some(reason) => <div className="stop-reason"> {React.string(reason)} </div>
      | None => React.null
      }}
      {switch model.haulError {
      | Some(msg) => <div className="haul-error"> {React.string(msg)} </div>
      | None => React.null
      }}
      {switch phase {
      | Finished(_) =>
        <>
          <div className="status">
            {React.string(status.emailNote->Option.getOr("done — waiting for the digest"))}
          </div>
          {status.emailedAt->Option.isSome
            ? <button className="take-photo" onClick={onNewHaul}>
                {React.string("Start a new haul")}
              </button>
            : React.null}
        </>
      | Finishing(_) =>
        <div className="status"> {React.string("finishing — uploading what's left")} </div>
      | _ =>
        <div className="haul-buttons">
          <label className="take-photo">
            <input
              className="visually-hidden"
              type_="file"
              accept="image/*"
              capture=#environment
              onChange={onTakePhoto}
            />
            {React.string("Take photo")}
          </label>
          <label className="take-photo">
            <input
              className="visually-hidden"
              type_="file"
              accept="image/*"
              multiple=true
              onChange={onAddPhotos}
            />
            {React.string("Add photos")}
          </label>
          <button className="take-photo" onClick={onDone}>
            {React.string("Done")}
          </button>
        </div>
      }}
      {switch phase {
      | Finished(_) | Finishing(_) => React.null
      | _ =>
        <div className="hint">
          {React.string("Put a quarter next to small items to show their size.")}
        </div>
      }}
      {Array.length(status.gems) > 0
        ? <ul className="items">
            {status.gems
            ->Array.map(gem =>
              <GemCard
                key={gem.findId}
                gem
                isOpen={model.openGem == Some(gem.findId)}
                onToggle=onToggleGem
              />
            )
            ->React.array}
          </ul>
        : React.null}
      {status.otherCount > 0
        ? <div className="status">
            {React.string(Int.toString(status.otherCount) ++ " other items seen, not gems")}
          </div>
        : React.null}
      {Array.length(status.failed) > 0
        ? <ul className="items">
            {status.failed
            ->Array.map(f =>
              <li className="item" key={f.sceneId}> {React.string(f.error)} </li>
            )
            ->React.array}
          </ul>
        : React.null}
    </div>
  }
}

@react.component
let make = () => {
  let rewind = Rewind.use(~name="reflip", ~enabled=DevFlag.viteDev, AppState.update, AppState.initialModel)
  let model = rewind.model
  let dispatch = rewind.dispatch

  // -- mount: restore a haul in progress from IndexedDB ---------------------
  React.useEffect0(() => {
    restoreHaul(dispatch)->Promise.ignore
    None
  })

  // -- background queue pump: one upload in flight at a time ----------------
  React.useEffect2(() => {
    switch rewind.live.haul {
    | Active(status) | Finishing(status) =>
      let sending =
        Array.find(rewind.live.queue, item => item.status == AppState.SendingNow)->Option.isSome
      if !sending {
        switch Array.find(rewind.live.queue, item => item.status == AppState.QueuedLocal) {
        | Some(item) => uploadOne(dispatch, status.haulId, item)->Promise.ignore
        | None => ()
        }
      }
    | _ => ()
    }
    None
  }, (rewind.live.queue, rewind.live.haul))

  // -- Done: once the local queue is drained, tell the brain ----------------
  React.useEffect2(() => {
    switch rewind.live.haul {
    | Finishing(status) if Array.length(rewind.live.queue) == 0 =>
      finishHaul(dispatch, status.haulId)->Promise.ignore
    | _ => ()
    }
    None
  }, (rewind.live.queue, rewind.live.haul))

  // -- poll the brain while the haul is open or not yet emailed -------------
  let pollHaulId = AppState.haulStatusOf(rewind.live.haul)->Option.map(s => s.haulId)->Option.getOr("")
  let pollActive = switch AppState.haulStatusOf(rewind.live.haul) {
  | Some(status) => status.doneAt == None || status.emailedAt == None
  | None => false
  }
  React.useEffect2(() => {
    if pollActive && pollHaulId != "" {
      let id = WebApi.setInterval(() => pollHaul(dispatch, pollHaulId)->Promise.ignore, 5000)
      Some(() => WebApi.clearInterval(id))
    } else {
      None
    }
  }, (pollHaulId, pollActive))

  // -- the new streaming scan flow: refs so Stop/New scan's edge effects
  // below can reach the live ScanApi.handle and revoke the current photo's
  // object URL. A plain React.useRef, not state — neither should ever
  // trigger a re-render on its own.
  let scanHandleRef: React.ref<option<ScanApi.handle>> = React.useRef(None)
  let scanPhotoUrlRef: React.ref<option<string>> = React.useRef(None)

  // -- Stop: the view only dispatches StopTapped; this is the edge effect
  // that actually asks the brain to stop, once stopRequested flips true.
  // It reads rewind.live, not model: while rewind is paused, model is a
  // past state, and a past StopTapped must not stop the live scan.
  React.useEffect1(() => {
    if rewind.live.scan.stopRequested {
      switch scanHandleRef.current {
      | Some(handle) => handle.stop()->Promise.ignore
      | None => ()
      }
    }
    None
  }, [rewind.live.scan.stopRequested])

  // -- New scan: the view only dispatches NewScan, which resets model.scan
  // back to ScanState.initialModel (phase Ready). This is the edge effect
  // that tears down any live connection and revokes the finished photo's
  // object URL once that reset lands (a no-op on first mount — Ready is
  // also the very first phase, before any handle or photo URL exists).
  // It reads rewind.live too: a jump to a past Ready entry must not abort
  // the live scan.
  React.useEffect1(() => {
    if rewind.live.scan.phase == ScanState.Ready {
      switch scanHandleRef.current {
      | Some(handle) =>
        handle.abort()
        scanHandleRef.current = None
      | None => ()
      }
      switch scanPhotoUrlRef.current {
      | Some(url) =>
        WebApi.revokeObjectURL(url)
        scanPhotoUrlRef.current = None
      | None => ()
      }
    }
    None
  }, [rewind.live.scan.phase])

  // A new photo for the scan flow: revoke the previous scan's object URL
  // and abort any live connection first (same guard runPhotoFlow's onChange
  // below applies), then hand off to the edge function above.
  let onScanFileChange = (event: ReactEvent.Form.t) => {
    let target = WebApi.eventTarget(event)
    switch WebApi.targetFiles(target)->Nullable.toOption {
    | None => ()
    | Some(files) =>
      if WebApi.fileListLength(files) > 0 {
        switch WebApi.fileListItem(files, 0)->Nullable.toOption {
        | None => ()
        | Some(file) =>
          switch scanHandleRef.current {
          | Some(handle) => handle.abort()
          | None => ()
          }
          switch scanPhotoUrlRef.current {
          | Some(url) => WebApi.revokeObjectURL(url)
          | None => ()
          }
          runScanFlow(
            dispatch,
            handle => scanHandleRef.current = Some(handle),
            url => scanPhotoUrlRef.current = Some(url),
            model.selectedModel,
            model.longEdge,
            file,
          )->Promise.ignore
        }
      }
    }
  }

  let onStoreNameChange = (event: ReactEvent.Form.t) =>
    dispatch(AppState.SetStoreName(WebApi.targetValue(WebApi.eventTarget(event))))

  let onStartHaul = (_event: ReactEvent.Mouse.t) =>
    startHaul(dispatch, String.trim(model.storeName))->Promise.ignore

  let onToggleGem = (findId: string) => dispatch(AppState.ToggleGem(findId))

  let onDone = (_event: ReactEvent.Mouse.t) => dispatch(AppState.DoneTapped)
  let onNewHaul = (_event: ReactEvent.Mouse.t) => {
    dispatch(AppState.NewHaul)
    // Forget the finished haul, or a reload would bring it back.
    WebApi.idbDel(AppState.currentHaulKey)->Promise.ignore
  }

  let onTakeHaulPhoto = (event: ReactEvent.Form.t) =>
    switch AppState.haulStatusOf(model.haul) {
    | None => ()
    | Some(status) =>
      switch WebApi.targetFiles(WebApi.eventTarget(event))->Nullable.toOption {
      | None => ()
      | Some(files) =>
        switch WebApi.fileListItem(files, 0)->Nullable.toOption {
        | None => ()
        | Some(file) => queuePhoto(dispatch, status.haulId, file)->Promise.ignore
        }
      }
    }

  let onAddHaulPhotos = (event: ReactEvent.Form.t) =>
    switch AppState.haulStatusOf(model.haul) {
    | None => ()
    | Some(status) =>
      switch WebApi.targetFiles(WebApi.eventTarget(event))->Nullable.toOption {
      | None => ()
      | Some(files) =>
        queuePhotos(dispatch, status.haulId, WebApi.fileListToArray(files))->Promise.ignore
      }
    }

  let isScanMode = switch model.haul {
  | NoHaul => true
  | Starting | Active(_) | Finishing(_) | Finished(_) => false
  }

  <div className="page">
    {isScanMode ? React.null : <h1> {React.string("reflip")} </h1>}
    {switch model.haul {
    | NoHaul =>
      <ScanShell model dispatch onScanFileChange onStoreNameChange onStartHaul />
    | Starting => <div className="status"> {React.string("starting haul…")} </div>
    | Active(status) | Finishing(status) | Finished(status) =>
      <HaulView
        model
        phase={model.haul}
        status
        onTakePhoto={onTakeHaulPhoto}
        onAddPhotos={onAddHaulPhotos}
        onDone
        onNewHaul
        onToggleGem
      />
    }}
  </div>
}
