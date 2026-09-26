// AppState.update: each msg against the expected model. Both pickers, a
// reply, an error, and a second photo clearing the previous one. Then haul
// mode's own reducer logic (docs/spec-haul-mode.md "Step 5: phone").

let sampleReply: Types.sceneReply = {
  Types.sceneId: "test-scene",
  model: "claude-sonnet-5",
  fixture: true,
  outputPath: "/tmp/test.json",
  items: [],
  imageWidth: 800,
  imageHeight: 600,
  timing: {Types.serverMs: 1.0, claudeMs: 2.0, ebayMs: 3.0},
  cost: {
    Types.usd: 0.01,
    inputTokens: 10,
    outputTokens: 5,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    webSearches: 0,
  },
  ebayNote: None,
  quarterSeen: false,
}

let sampleHaulStatus: Types.haulStatus = {
  Types.haulId: "haul-1",
  name: Some("Goodwill"),
  startedAt: "2026-09-24T00:00:00.000Z",
  doneAt: None,
  emailedAt: None,
  costUsd: 0.3,
  maxUsd: 10.0,
  gemMinUsd: 20.0,
  stopReason: None,
  emailNote: None,
  counts: {Types.queued: 1, running: 0, valued: 2, failed: 0},
  gems: [],
  otherCount: 5,
  failed: [],
}

// A real Blob (Node's own global, not a cast) so queue items can hold one —
// see WebApi.res's header comment on idbValue for why this file never
// asserts its way to a blob.
let testBlob = (): WebApi.blob => WebApi.makeBlobWithType([], {WebApi.type_: "image/jpeg"})

let runHaul = () => {
  TestKit.section("AppState.update — haul mode")

  let h0 = AppState.initialModel
  TestKit.check("a fresh model has no haul", h0.haul == AppState.NoHaul)
  TestKit.check("a fresh model has an empty queue", h0.queue == [])
  TestKit.check(
    "after a reload the uploaded chip shows the brain's scene count",
    AppState.uploadedShown(h0, {Types.queued: 1, running: 1, valued: 4, failed: 0}) == 6,
  )
  TestKit.check(
    "the uploaded chip shows the local count while the brain lags",
    AppState.uploadedShown({...h0, uploadedCount: 3}, {Types.queued: 0, running: 0, valued: 2, failed: 0}) == 3,
  )

  // -- starting and restoring a haul --------------------------------------
  let h1 = AppState.update(h0, AppState.SetStoreName("Goodwill"))
  TestKit.check("SetStoreName sets the typed name", h1.storeName == "Goodwill")

  let h2 = AppState.update(h1, AppState.StartHaul)
  TestKit.check("StartHaul moves to Starting", h2.haul == AppState.Starting)

  let h3 = AppState.update(h2, AppState.HaulStarted(sampleHaulStatus))
  TestKit.check(
    "HaulStarted moves to Active with the status",
    h3.haul == AppState.Active(sampleHaulStatus),
  )
  TestKit.check(
    "haulStatusOf reads the status back out of Active",
    AppState.haulStatusOf(h3.haul) == Some(sampleHaulStatus),
  )

  let h3b = AppState.update(h2, AppState.HaulStartFailed("could not reach the server"))
  TestKit.check("a failed start falls back to NoHaul", h3b.haul == AppState.NoHaul)
  TestKit.check(
    "a failed start records the error",
    h3b.haulError == Some("could not reach the server"),
  )

  // -- the IndexedDB key layout, as pure string logic ---------------------
  TestKit.check(
    "queueKey builds q|<haulId>|<clientId>",
    AppState.queueKey("haul-1", "client-a") == "q|haul-1|client-a",
  )
  TestKit.check(
    "parseQueueKey is queueKey's inverse",
    AppState.parseQueueKey("q|haul-1|client-a") == Some(("haul-1", "client-a")),
  )
  TestKit.check("parseQueueKey rejects a non-queue key", AppState.parseQueueKey("haul") == None)

  // -- queuing a photo, and never queuing the same client id twice -------
  let blobA = testBlob()
  let blobB = testBlob()
  let h4 = AppState.update(h3, AppState.PhotoQueued("client-a", blobA))
  TestKit.check("a queued photo is added to the queue", Array.length(h4.queue) == 1)
  TestKit.check(
    "a queued photo starts as QueuedLocal with no attempts",
    switch h4.queue {
    | [item] => item.status == AppState.QueuedLocal && item.attempts == 0
    | _ => false
    },
  )
  let h4b = AppState.update(h4, AppState.PhotoQueued("client-a", blobB))
  TestKit.check("a duplicate client id is not queued twice", Array.length(h4b.queue) == 1)

  // -- restoring the queue from IndexedDB on load --------------------------
  let h5 = AppState.update(h3, AppState.QueueRestored([("client-a", blobA), ("client-b", blobB)]))
  TestKit.check("QueueRestored adds every restored item", Array.length(h5.queue) == 2)

  // -- uploading: started, ok, failed, retried -----------------------------
  let h6 = AppState.update(h5, AppState.UploadStarted("client-a"))
  TestKit.check(
    "UploadStarted marks that one item SendingNow, and no other",
    switch Array.find(h6.queue, i => i.clientId == "client-a") {
    | Some(item) => item.status == AppState.SendingNow
    | None => false
    } &&
      switch Array.find(h6.queue, i => i.clientId == "client-b") {
      | Some(item) => item.status == AppState.QueuedLocal
      | None => false
      },
  )

  let h7 = AppState.update(h6, AppState.HaulUploadOk("client-a", "scene-1"))
  TestKit.check("a successful upload removes the item", Array.length(h7.queue) == 1)
  TestKit.check("a successful upload counts as uploaded", h7.uploadedCount == 1)

  let h8 = AppState.update(h6, AppState.HaulUploadFailed("client-a", "could not reach the server"))
  TestKit.check(
    "a failed upload keeps the item, waiting to retry",
    switch Array.find(h8.queue, i => i.clientId == "client-a") {
    | Some(item) => item.status == AppState.WaitingRetry && item.attempts == 1
    | None => false
    },
  )
  TestKit.check(
    "a failed upload records the error",
    h8.haulError == Some("could not reach the server"),
  )

  let h9 = AppState.update(h8, AppState.RetryDue("client-a"))
  TestKit.check(
    "the retry timer puts the item back in the queue, attempts kept",
    switch Array.find(h9.queue, i => i.clientId == "client-a") {
    | Some(item) => item.status == AppState.QueuedLocal && item.attempts == 1
    | None => false
    },
  )

  TestKit.check(
    "the backoff is 5s, then 15s, then 60s forever",
    AppState.retryDelayMs(1) == 5000 &&
      AppState.retryDelayMs(2) == 15000 &&
      AppState.retryDelayMs(3) == 60000 &&
      AppState.retryDelayMs(9) == 60000,
  )

  // -- status polling and done ---------------------------------------------
  let h10 = AppState.update(h3, AppState.PollTick)
  TestKit.check("PollTick counts polls", h10.pollCount == 1)

  let updatedStatus = {...sampleHaulStatus, costUsd: 1.2}
  let h11 = AppState.update(h3, AppState.StatusLoaded(updatedStatus))
  TestKit.check(
    "StatusLoaded refreshes the status while Active",
    h11.haul == AppState.Active(updatedStatus),
  )

  let h12 = AppState.update(h3, AppState.DoneTapped)
  TestKit.check(
    "DoneTapped moves Active to Finishing",
    h12.haul == AppState.Finishing(sampleHaulStatus),
  )
  TestKit.check("DoneTapped resets doneAttempts", h12.doneAttempts == 0)

  // -- Done auto-retry (decision 10): DoneFailed counts attempts, a later
  // DoneSent or NewHaul clears them again ----------------------------------
  let h12f = AppState.update(h12, AppState.DoneFailed("network error"))
  TestKit.check("DoneFailed counts the first failed attempt", h12f.doneAttempts == 1)
  let h12f2 = AppState.update(h12f, AppState.DoneFailed("network error"))
  TestKit.check("a second DoneFailed counts to 2", h12f2.doneAttempts == 2)

  let doneStatus = {...sampleHaulStatus, doneAt: Some("2026-09-24T01:00:00.000Z")}
  let h13 = AppState.update(h12f2, AppState.DoneSent(doneStatus))
  TestKit.check("DoneSent moves Finishing to Finished", h13.haul == AppState.Finished(doneStatus))
  TestKit.check("DoneSent resets doneAttempts", h13.doneAttempts == 0)

  let h13f = AppState.update(h12f, AppState.NewHaul)
  TestKit.check("NewHaul resets doneAttempts too", h13f.doneAttempts == 0)

  let h14 = AppState.update(h13, AppState.NewHaul)
  TestKit.check("NewHaul resets back to NoHaul", h14.haul == AppState.NoHaul)
  TestKit.check("NewHaul clears the queue", h14.queue == [])
  TestKit.check("NewHaul clears the store name", h14.storeName == "")

  // -- ToggleGem: same id closes, another id switches, None opens ---------
  TestKit.check("a fresh model has no open gem card", h0.openGem == None)
  let g1 = AppState.update(h0, AppState.ToggleGem("find-a"))
  TestKit.check("ToggleGem opens a closed card", g1.openGem == Some("find-a"))
  let g2 = AppState.update(g1, AppState.ToggleGem("find-b"))
  TestKit.check("ToggleGem on a different id switches the open card", g2.openGem == Some("find-b"))
  let g3 = AppState.update(g2, AppState.ToggleGem("find-b"))
  TestKit.check("ToggleGem on the open card's own id closes it", g3.openGem == None)
}

let run = () => {
  TestKit.section("AppState.update")

  let m0 = AppState.initialModel
  TestKit.check("initial model defaults to Sonnet 5", m0.selectedModel == Shared.Sonnet5)
  TestKit.check("initial model defaults to 1568 long edge", m0.longEdge == 1568)

  // -- both pickers ----------------------------------------------------
  let m1 = AppState.update(m0, AppState.SetModel(Shared.Opus5_5))
  TestKit.check("SetModel picks Opus 5.5", m1.selectedModel == Shared.Opus5_5)

  let m2 = AppState.update(m0, AppState.SetLongEdge(2576))
  TestKit.check("SetLongEdge picks 2576", m2.longEdge == 2576)

  // -- a reply -----------------------------------------------------------
  let m3 = AppState.update(m0, AppState.UploadOk(sampleReply, 456.0))
  TestKit.check("a reply sets status to Waiting", m3.status == AppState.Waiting)
  TestKit.check("a reply is stored on the model", m3.reply == Some(sampleReply))
  TestKit.check("a reply records the round trip", m3.rttMs == Some(456.0))

  // -- an error ------------------------------------------------------------
  let m4 = AppState.update(m0, AppState.UploadErr("could not reach the server"))
  TestKit.check(
    "an error sets the status line",
    m4.status == AppState.ErrorStatus("could not reach the server"),
  )
  let m4b = AppState.update(m0, AppState.ResizeErr("could not read that photo"))
  TestKit.check(
    "a resize error also sets the status line",
    m4b.status == AppState.ErrorStatus("could not read that photo"),
  )

  // -- SelectItem ----------------------------------------------------------
  let m6 = AppState.update(m3, AppState.SelectItem(2))
  TestKit.check("SelectItem stores the tapped index", m6.selected == Some(2))
  let m6b = AppState.update(m6, AppState.SelectItem(0))
  TestKit.check("a second SelectItem replaces the first", m6b.selected == Some(0))

  // -- PhotoUrlReady ---------------------------------------------------------
  let m7 = AppState.update(m0, AppState.PhotoUrlReady("blob:http://x/1"))
  TestKit.check(
    "PhotoUrlReady stores the object URL",
    m7.photoUrl == Some("blob:http://x/1"),
  )

  // -- a second photo clears the previous reply, timings, selection and URL -
  let withReply = {
    ...m3,
    uploadBytes: Some(12345),
    resizeMs: Some(78.0),
    photoUrl: Some("blob:http://x/1"),
    selected: Some(1),
  }
  let m5 = AppState.update(withReply, AppState.StartPhoto)
  TestKit.check("a second photo resets status to Resizing", m5.status == AppState.Resizing)
  TestKit.check("a second photo clears the old reply", m5.reply == None)
  TestKit.check("a second photo clears the old upload size", m5.uploadBytes == None)
  TestKit.check("a second photo clears the old resize time", m5.resizeMs == None)
  TestKit.check("a second photo clears the old round trip", m5.rttMs == None)
  TestKit.check("a second photo clears the old photo url", m5.photoUrl == None)
  TestKit.check("a second photo clears the selected item", m5.selected == None)
  TestKit.check(
    "a second photo keeps the chosen model",
    m5.selectedModel == withReply.selectedModel,
  )

  runHaul()
}
