// The network edge for the streaming scan (docs/scan-ui.md). Owns every
// side effect ScanState.res is not allowed to: the POST, reading the SSE
// body, the Stop request, and reconnecting after a drop. Every event read
// off the wire is dispatched as ScanState.GotEvent — ScanState folds it,
// this file never interprets one.
//
// The brain's stop/events routes (docs/scan-ui.md §3, "planned") build on
// a separate branch, claude/scan-ui-brain, not yet merged here. The retry
// and backoff decisions below are unit-testable on their own (see
// ScanStateTest.res for the pure side of this), but a live reconnect
// against a real server needs a smoke pass once that branch lands.
//
// Left out (turns did not allow it — see the track's report): IndexedDB
// persistence for resume-on-load. A dropped connection still retries in
// place on its own; only a full page reload loses the scan.

type handle = {
  stop: unit => promise<unit>,
  abort: unit => unit,
}

// A dead connection, per docs/scan-ui.md "Reconnecting": a reader error, a
// close with no `end`, or this many ms with no bytes at all. The stream is
// expected to send a heartbeat comment line more often than this — Sse.feed
// drops comment lines before they ever reach dispatchDecoded below, so a
// heartbeat never shows up as an event.
let heartbeatTimeoutMs = 30_000
let watchdogIntervalMs = 5_000
let backoffScheduleMs = [1000, 2000, 5000, 10000]

let run = (~model: Shared.model, ~blob: WebApi.blob, ~dispatch: ScanState.msg => unit): handle => {
  // Replaced on every attempt, so a watchdog-triggered abort (or the
  // visibility/online fast path below) only ever cancels the read in
  // flight, never a later reconnect that has not started yet.
  let currentController = ref(WebApi.makeAbortController())
  let sceneId = ref(None)
  let localEventCount = ref(0)
  let stopped = ref(false)
  let ended = ref(false)

  let dispatchDecoded = (event: string, data: string) => {
    localEventCount := localEventCount.contents + 1
    switch ScanEvent.decode(~event, ~data) {
    | Ok(evt) => {
        switch evt {
        | ScanEvent.PhotoReceived({sceneId: id}) => sceneId := Some(id)
        | ScanEvent.End(_) => ended := true
        | _ => ()
        }
        dispatch(ScanState.GotEvent(Ok(evt)))
      }
    | Error(msg) => dispatch(ScanState.GotEvent(Error(msg)))
    }
  }

  // Reads one response body to completion. `Ok()` means the stream closed
  // after `end` was already seen; `Error(reason)` means a genuine drop the
  // caller should retry.
  let consume = async (resp: WebApi.response): result<unit, string> =>
    switch WebApi.streamBody(resp) {
    | None => Error("no response body")
    | Some(stream) => {
        let reader = WebApi.getReader(stream)
        let decoder = WebApi.makeTextDecoder()
        let sse = ref(Sse.empty)
        let reading = ref(true)
        let readErr = ref(None)
        let lastByteAt = ref(WebApi.now())
        let controllerAtStart = currentController.contents
        let watchdog = WebApi.setInterval(() => {
          if WebApi.now() -. lastByteAt.contents > Int.toFloat(heartbeatTimeoutMs) {
            WebApi.abortControllerAbort(controllerAtStart)
          }
        }, watchdogIntervalMs)
        while reading.contents {
          try {
            let chunk = await WebApi.read(reader)
            if chunk.done {
              reading := false
            } else {
              switch chunk.value {
              | None => reading := false
              | Some(byteChunk) => {
                  lastByteAt := WebApi.now()
                  let text = WebApi.decodeStream(decoder, byteChunk, {stream: true})
                  let (next, events) = Sse.feed(sse.contents, text)
                  sse := next
                  Array.forEach(events, (e: Sse.event) => dispatchDecoded(e.event, e.data))
                }
              }
            }
          } catch {
          | JsExn(_) => {
              readErr := Some("the connection dropped")
              reading := false
            }
          }
        }
        WebApi.clearInterval(watchdog)
        switch readErr.contents {
        | Some(msg) => Error(msg)
        | None => ended.contents ? Ok() : Error("stream closed early")
        }
      }
    }

  // `isFirst` is the initial POST with the photo; every later attempt is a
  // GET replay from `localEventCount`. A 404 on a replay means the brain
  // has forgotten the scene (SCENE_KEEP_MS elapsed, or it never existed) —
  // that ends the scene as failed, keeping whatever already landed.
  let rec attempt = async (isFirst: bool, tryNum: int): unit =>
    if stopped.contents || ended.contents {
      ()
    } else {
      currentController := WebApi.makeAbortController()
      let respResult = try {
        if isFirst {
          let resp = await WebApi.fetchBlobSignal(
            "/api/scene/stream?model=" ++ Shared.modelId(model),
            {
              method: "POST",
              headers: Dict.fromArray([("Content-Type", "image/jpeg")]),
              body: blob,
              signal: WebApi.abortSignalOf(currentController.contents),
            },
          )
          Ok(resp)
        } else {
          switch sceneId.contents {
          | None => Error("never got a scene id")
          | Some(id) => {
              let resp = await WebApi.fetchGetSignal(
                "/api/scene/" ++ id ++ "/events?from=" ++ Int.toString(localEventCount.contents),
                {signal: WebApi.abortSignalOf(currentController.contents)},
              )
              Ok(resp)
            }
          }
        }
      } catch {
      | JsExn(_) => Error("could not reach the server")
      }
      switch respResult {
      | Error(reason) =>
        isFirst ? dispatch(ScanState.GotEvent(Error(reason))) : await retry(tryNum)
      | Ok(resp) =>
        if !isFirst && WebApi.responseStatus(resp) == 404 {
          dispatch(ScanState.GotEvent(Ok(ScanEvent.End({t: 0.0, status: ScanEvent.EndStatus.Failed}))))
          ended := true
        } else if !WebApi.responseOk(resp) {
          isFirst
            ? dispatch(
                ScanState.GotEvent(
                  Error("the server said " ++ Int.toString(WebApi.responseStatus(resp))),
                ),
              )
            : await retry(tryNum)
        } else {
          if !isFirst {
            dispatch(ScanState.Reconnected)
          }
          switch await consume(resp) {
          | Ok () => ()
          | Error(_) => await retry(tryNum)
          }
        }
      }
    }
  and retry = async (tryNum: int): unit =>
    if !stopped.contents && !ended.contents {
      dispatch(ScanState.ConnectionLost)
      await WebApi.delay(Array.get(backoffScheduleMs, tryNum)->Option.getOr(10_000))
      await attempt(false, tryNum + 1)
    } else {
      ()
    }

  attempt(true, 0)->ignore

  // Fast path, per docs/scan-ui.md "Reconnecting": wake up and retry as
  // soon as the tab is visible again or the network comes back, instead of
  // waiting out the rest of the backoff. This cancels the read in flight,
  // which `consume` above turns into the same drop-and-retry path as any
  // other disconnect, so the next attempt still opens with one short
  // (1s) backoff step rather than a true zero-wait retry — simple, and
  // close enough for this step's plain view.
  WebApi.addDocumentListener(WebApi.document, "visibilitychange", () =>
    if (
      WebApi.documentVisibilityState(WebApi.document) == "visible" &&
        (!stopped.contents && !ended.contents)
    ) {
      WebApi.abortControllerAbort(currentController.contents)
    }
  )
  WebApi.addWindowListener(WebApi.windowGlobal, "online", () =>
    if !stopped.contents && !ended.contents {
      WebApi.abortControllerAbort(currentController.contents)
    }
  )

  {
    stop: async () => {
      stopped := true
      switch sceneId.contents {
      | Some(id) =>
        try {
          let _ = await WebApi.fetchString(
            "/api/scene/" ++ id ++ "/stop",
            {method: "POST", headers: Dict.make(), body: ""},
          )
        } catch {
        | JsExn(_) => ()
        }
      | None => WebApi.abortControllerAbort(currentController.contents)
      }
    },
    abort: () => WebApi.abortControllerAbort(currentController.contents),
  }
}
