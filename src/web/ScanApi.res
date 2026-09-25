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

// Bug B/C (288738f review): whether the attempt loop may keep going. Only
// the scan reaching its authoritative end (`ended`), or this handle being
// abandoned outright by a newer one (`cancelled`), blocks a reconnect. A
// merely `stopped` scan (Stop tapped, still waiting for the authoritative
// `end`) must NOT block it: a drop between Stop and `end` still needs to
// reconnect and see that `end` land (bug C), and on its own `stopped`
// does not mean an in-flight event belongs to some other, newer scan
// (`cancelled` covers that instead, bug B).
let shouldContinue = (~cancelled: bool, ~ended: bool): bool => !cancelled && !ended

// Bug D: the try-count to hand to the next retry. A response that came
// back OK — even if the body later dropped mid-stream — is a *good*
// reconnect, so the backoff for that later drop restarts at the short
// end instead of continuing to climb a streak that already ended.
let tryNumAfter = (~gotGoodResponse: bool, ~tryNum: int): int => gotGoodResponse ? 0 : tryNum

// Bug A (288738f review): what one attempt at reaching the server came
// back with. `NoSceneId` is a reconnect attempted before `photo-received`
// ever landed — there is no id to reconnect to, and no later attempt can
// change that, so it must not be retried like an ordinary drop.
type connectResult =
  | ConnectFailed(string)
  | NoSceneId
  | Connected(WebApi.response)

let run = (~model: Shared.model, ~blob: WebApi.blob, ~dispatch: ScanState.msg => unit): handle => {
  // Replaced on every attempt, so a watchdog-triggered abort (or the
  // visibility/online fast path below) only ever cancels the read in
  // flight, never a later reconnect that has not started yet.
  let currentController = ref(WebApi.makeAbortController())
  let sceneId = ref(None)
  let localEventCount = ref(0)
  // Bug B (288738f review): set only by `abort` below, when a newer `run`
  // call (a new photo) replaces this one. Distinct from the scan's own
  // `ended` — `cancelled` means "this handle is abandoned", not "the scan
  // is over".
  let cancelled = ref(false)
  let ended = ref(false)

  // Bug A/B: the terminal path for a send that can never succeed — the
  // first POST failed outright, or a reconnect has no scene id to use.
  // Dispatches once and marks the run over; nothing after this retries.
  let fail = (reason: string) => {
    dispatch(ScanState.SendFailed(reason))
    ended := true
  }

  let dispatchDecoded = (event: string, data: string) =>
    // Bug B: once cancelled, a read that was already in flight when
    // `abort` fired must not mutate `sceneId`/`ended` or dispatch into
    // what is now a different scan's model.
    if !cancelled.contents {
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
    if !shouldContinue(~cancelled=cancelled.contents, ~ended=ended.contents) {
      ()
    } else {
      currentController := WebApi.makeAbortController()
      let controllerForAttempt = currentController.contents
      // Bug D: covers the connect itself, not just the body — a fetch
      // that never gets a response at all (a hung DNS lookup, a server
      // that accepts the connection and never answers) had no timeout
      // until a response body existed for `consume`'s own watchdog above
      // to watch. Reuses the same 30s dead-connection threshold.
      let connectWatchdog = WebApi.setTimeout(() => {
        WebApi.abortControllerAbort(controllerForAttempt)
      }, heartbeatTimeoutMs)
      let respResult: connectResult = try {
        if isFirst {
          let resp = await WebApi.fetchBlobSignal(
            "/api/scene/stream?model=" ++ Shared.modelId(model),
            {
              method: "POST",
              headers: Dict.fromArray([("Content-Type", "image/jpeg")]),
              body: blob,
              signal: WebApi.abortSignalOf(controllerForAttempt),
            },
          )
          Connected(resp)
        } else {
          switch sceneId.contents {
          | None => NoSceneId
          | Some(id) => {
              let resp = await WebApi.fetchGetSignal(
                "/api/scene/" ++ id ++ "/events?from=" ++ Int.toString(localEventCount.contents),
                {signal: WebApi.abortSignalOf(controllerForAttempt)},
              )
              Connected(resp)
            }
          }
        }
      } catch {
      | JsExn(_) => ConnectFailed("could not reach the server")
      }
      WebApi.clearTimeout(connectWatchdog)
      switch respResult {
      | NoSceneId =>
        // Bug A: the very first stream dropped before `photo-received`
        // ever landed. There is no id to reconnect to, and no later
        // attempt can change that — retrying this looped forever.
        fail("the connection dropped before the scan started")
      | ConnectFailed(reason) => isFirst ? fail(reason) : await retry(tryNum)
      | Connected(resp) =>
        if !isFirst && WebApi.responseStatus(resp) == 404 {
          dispatch(ScanState.GotEvent(Ok(ScanEvent.End({t: 0.0, status: ScanEvent.EndStatus.Failed}))))
          ended := true
        } else if !WebApi.responseOk(resp) {
          isFirst
            ? fail("the server said " ++ Int.toString(WebApi.responseStatus(resp)))
            : await retry(tryNum)
        } else {
          if !isFirst {
            dispatch(ScanState.Reconnected)
          }
          switch await consume(resp) {
          | Ok () => ()
          | Error(_) => await retry(tryNumAfter(~gotGoodResponse=true, ~tryNum))
          }
        }
      }
    }
  and retry = async (tryNum: int): unit =>
    if shouldContinue(~cancelled=cancelled.contents, ~ended=ended.contents) {
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
  //
  // Bug A: gated on having a sceneId, so this can never abort the initial
  // POST — there is no scene to reconnect to yet, and (per `NoSceneId`
  // above) no way back from cancelling it early. Bug C: gated on
  // `shouldContinue`, not on a `stopped` flag — a scan that is merely
  // stopped, still waiting on the authoritative `end`, must still
  // fast-reconnect. Bug B: named functions, not inline closures, so
  // `abort` below can remove exactly this run's own listeners.
  let onVisibilityChange = () =>
    if (
      WebApi.documentVisibilityState(WebApi.document) == "visible" &&
        shouldContinue(~cancelled=cancelled.contents, ~ended=ended.contents) &&
        sceneId.contents->Option.isSome
    ) {
      WebApi.abortControllerAbort(currentController.contents)
    }
  let onOnline = () =>
    if (
      shouldContinue(~cancelled=cancelled.contents, ~ended=ended.contents) &&
        sceneId.contents->Option.isSome
    ) {
      WebApi.abortControllerAbort(currentController.contents)
    }
  WebApi.addDocumentListener(WebApi.document, "visibilitychange", onVisibilityChange)
  WebApi.addWindowListener(WebApi.windowGlobal, "online", onOnline)

  {
    stop: async () => {
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
    abort: () => {
      // Bug B: mark this handle's events dead before touching anything
      // else, so `dispatchDecoded` on a read that is already in flight
      // stops folding into the model the instant it next runs, then
      // remove this run's own visibility/online listeners so they can
      // never fire into whatever newer scan replaces it.
      cancelled := true
      WebApi.abortControllerAbort(currentController.contents)
      WebApi.removeDocumentListener(WebApi.document, "visibilitychange", onVisibilityChange)
      WebApi.removeWindowListener(WebApi.windowGlobal, "online", onOnline)
    },
  }
}
