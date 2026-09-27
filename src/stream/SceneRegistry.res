// Keeps a scan scene alive on the brain after the phone's own connection
// drops. docs/scan-ui.md §1 decision 3: a dropped connection must not stop
// the Claude call. A scene is an append-only buffer of its encoded SSE
// events plus a set of open HTTP responses ("listeners") that get the live
// feed. StreamRoute's POST connection is the first listener; a later
// GET /api/scene/:id/events reconnects as another one and first replays
// the buffer it missed.
//
// Buffer index 0 is always `photo-received`, the first event a scene ever
// pushes. Heartbeat comments never go in the buffer: a listener that
// reconnects should replay real events, not a log of "still here".

type status =
  | Running
  | Ended(ScanEvent.EndStatus.t)

type scene = {
  mutable status: status,
  mutable endedAt: option<float>,
  buffer: array<string>,
  listeners: Map.t<string, Node.HttpServer.response>,
  controller: Fetch.AbortController.t,
  mutable heartbeatId: option<timeoutId>,
}

let scenes: Map.t<string, scene> = Map.make()

let heartbeatMs = 10_000

// Tests only, per STREAM_DROP_AFTER_MS's own pattern: a function, not a
// frozen constant, so a test can set the env var and have the very next
// sweep see it. fromEnv leaves this unset in real use, so the real answer
// is always the 30-minute default from docs/scan-ui.md §3.
let sceneKeepMs = (): int =>
  Config.getEnv("SCENE_KEEP_MS")->Option.flatMap(s => Int.fromString(s))->Option.getOr(30 * 60 * 1000)

let sseHeaders = Dict.fromArray([
  ("Content-Type", "text/event-stream; charset=utf-8"),
  ("Cache-Control", "no-cache, no-transform"),
  ("X-Accel-Buffering", "no"),
])

// See the old StreamRoute.res onResponseError doc comment: an unlistened
// "error" on a response is an uncaught exception, and a write that loses
// the race with a client abort can raise one. Every listener needs this,
// not just the first.
let beginSseResponse = (res: Node.HttpServer.response): unit => {
  Node.HttpServer.writeHead(res, 200, sseHeaders)
  Node.HttpServer.flushHeaders(res)
  Node.HttpServer.onResponseError(res, "error", () => ())
}

let writeToListener = (res: Node.HttpServer.response, text: string): unit =>
  if !Node.HttpServer.writableEnded(res) {
    Node.HttpServer.write(res, text)
  }

let closeListener = (res: Node.HttpServer.response): unit =>
  if !Node.HttpServer.writableEnded(res) {
    Node.HttpServer.endWithBody(res, "")
  }

let broadcast = (scene: scene, text: string): unit =>
  Map.forEach(scene.listeners, res => writeToListener(res, text))

let stopHeartbeat = (scene: scene): unit =>
  switch scene.heartbeatId {
  | Some(id) => {
      clearTimeout(id)
      scene.heartbeatId = None
    }
  | None => ()
  }

let rec scheduleHeartbeat = (scene: scene): unit =>
  scene.heartbeatId = Some(
    setTimeout(() => {
      switch scene.status {
      | Running => {
          broadcast(scene, Sse.comment("heartbeat"))
          scheduleHeartbeat(scene)
        }
      | Ended(_) => ()
      }
    }, heartbeatMs),
  )

// Ends every open listener and forgets them. Called once a scene reaches
// `end` — nothing will ever push to it again.
let closeAllListeners = (scene: scene): unit => {
  Map.forEach(scene.listeners, closeListener)
  Map.clear(scene.listeners)
}

// Removes a listener from a scene. Never touches the scene's own status or
// its AbortController — a dropped connection must not stop the Claude
// call (docs/scan-ui.md §1 decision 3). Only `requestStop` may abort.
let detach = (sceneId: string, listenerId: string): unit =>
  switch Map.get(scenes, sceneId) {
  | None => ()
  | Some(scene) => Map.delete(scene.listeners, listenerId)->ignore
  }

// Drops scenes that ended more than sceneKeepMs() ago, so the map never
// grows without bound. Called once at the start of every `create`
// (docs/scan-ui.md §3: "Sweep expired scenes when a scene starts").
let sweep = (): unit => {
  let now = Date.now()
  let keepMs = Int.toFloat(sceneKeepMs())
  let expired = []
  Map.forEachWithKey(scenes, (scene, sceneId) =>
    switch (scene.status, scene.endedAt) {
    | (Ended(_), Some(endedAt)) if now -. endedAt > keepMs => Array.push(expired, sceneId)->ignore
    | _ => ()
    }
  )
  Array.forEach(expired, sceneId => Map.delete(scenes, sceneId)->ignore)
}

// Starts a new scene and attaches `res` — the POST connection — as its
// first listener. The buffer is empty at this point, so there is nothing
// to replay; every future event reaches `res` live, the same way it
// reaches any later GET reconnect.
let create = (sceneId: string, controller: Fetch.AbortController.t, res: Node.HttpServer.response): unit => {
  sweep()
  let scene = {
    status: Running,
    endedAt: None,
    buffer: [],
    listeners: Map.make(),
    controller,
    heartbeatId: None,
  }
  Map.set(scenes, sceneId, scene)
  beginSseResponse(res)
  let listenerId = Node.Crypto.randomUUID()
  Map.set(scene.listeners, listenerId, res)
  Node.HttpServer.onClose(res, "close", () => detach(sceneId, listenerId))
  scheduleHeartbeat(scene)
}

// Encodes `evt`, appends it to the scene's buffer, and writes it to every
// current listener. An `end` event also ends and forgets every listener
// and stops the heartbeat — see closeAllListeners.
let push = (sceneId: string, evt: ScanEvent.t): unit =>
  switch Map.get(scenes, sceneId) {
  | None => ()
  | Some(scene) =>
    switch scene.status {
    // A scene that already ended never pushes again: every StreamRoute
    // branch pushes exactly one `end`, as its last event.
    | Ended(_) => ()
    | Running => {
        let (event, data) = ScanEvent.toSse(evt)
        let text = Sse.encode(~event, ~data)
        Array.push(scene.buffer, text)->ignore
        broadcast(scene, text)
        switch evt {
        | ScanEvent.End({status}) => {
            scene.status = Ended(status)
            scene.endedAt = Some(Date.now())
            stopHeartbeat(scene)
            closeAllListeners(scene)
          }
        | _ => ()
        }
      }
    }
  }

type attachOutcome = NotFound | Attached

// Replays the buffer from index `from`, then either adds `res` as a live
// listener (scene still running) or closes it (scene already ended — see
// docs/scan-ui.md §3's GET /api/scene/:id/events). NotFound covers both an
// id that never existed and one `sweep` has since expired; either way the
// caller answers 404.
let attach = (sceneId: string, res: Node.HttpServer.response, ~from: int): attachOutcome =>
  switch Map.get(scenes, sceneId) {
  | None => NotFound
  | Some(scene) => {
      beginSseResponse(res)
      let start = from < 0 ? 0 : from
      for i in start to Array.length(scene.buffer) - 1 {
        writeToListener(res, Array.getUnsafe(scene.buffer, i))
      }
      switch scene.status {
      | Running => {
          let listenerId = Node.Crypto.randomUUID()
          Map.set(scene.listeners, listenerId, res)
          Node.HttpServer.onClose(res, "close", () => detach(sceneId, listenerId))
        }
      | Ended(_) => closeListener(res)
      }
      Attached
    }
  }

// Ends a scene on purpose, apart from the stream connection
// (docs/scan-ui.md §3's POST /api/scene/:id/stop). Aborts the scene's
// Claude call only if it is still running; a stop on an already-ended
// scene is a no-op read of its final status. None means the id is unknown
// or expired.
let requestStop = (sceneId: string): option<status> =>
  switch Map.get(scenes, sceneId) {
  | None => None
  | Some(scene) => {
      switch scene.status {
      | Running => Fetch.AbortController.abort(scene.controller)
      | Ended(_) => ()
      }
      Some(scene.status)
    }
  }
