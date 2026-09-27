// The two calls the page makes to the brain: POST the resized JPEG to
// /api/scene, then log {rttMs, resizeMs} to /api/scene/<id>/rtt. Round trip
// is timed with performance.now() from just before the request to the
// parsed reply, per the brief.

let postScene = async (modelId: string, blob: WebApi.blob): result<
  (Types.sceneReply, float),
  string,
> => {
  let start = WebApi.now()
  try {
    let resp = await WebApi.fetchBlob(
      "/api/scene?model=" ++ modelId,
      {
        WebApi.method: "POST",
        headers: Dict.fromArray([("Content-Type", "image/jpeg")]),
        body: blob,
      },
    )
    if WebApi.responseOk(resp) {
      let json = await WebApi.responseJson(resp)
      switch Shared.decodeSceneReply(json) {
      | Ok(reply) => Ok((reply, WebApi.now() -. start))
      | Error(msg) => Error("could not read the reply: " ++ msg)
      }
    } else {
      // The brain puts a readable reason in {"error": ...}, for example the 504
      // after a Claude timeout. A body that is not JSON (the generic 500) falls
      // back to the status code alone.
      let said = "the server said " ++ Int.toString(WebApi.responseStatus(resp))
      let reason = try {
        Json.stringField(await WebApi.responseJson(resp), "error")
      } catch {
      | JsExn(_) => None
      }
      Error(reason->Option.mapOr(said, r => said ++ ": " ++ r))
    }
  } catch {
  | JsExn(_) => Error("could not reach the server")
  }
}

let postRtt = async (sceneId: string, rttMs: float, resizeMs: float): result<unit, string> => {
  let body = Json.obj([("rttMs", Json.num(rttMs)), ("resizeMs", Json.num(resizeMs))])
  try {
    let resp = await WebApi.fetchString(
      "/api/scene/" ++ sceneId ++ "/rtt",
      {
        WebApi.method: "POST",
        headers: Dict.fromArray([("Content-Type", "application/json")]),
        body: JSON.stringify(body),
      },
    )
    WebApi.responseOk(resp) ? Ok() : Error("the server said " ++ Int.toString(WebApi.responseStatus(resp)))
  } catch {
  | JsExn(_) => Error("could not reach the server")
  }
}

// -- Haul mode (docs/spec-haul-mode.md "Step 5: phone") -------------------
// Same error convention as postScene above: a readable {"error": ...} body
// when the brain sends one (a 404, a 409, a 503 with no API key, ...),
// else the bare status code.

let readErrorReason = async (resp: WebApi.response): string => {
  let said = "the server said " ++ Int.toString(WebApi.responseStatus(resp))
  let reason = try {
    Json.stringField(await WebApi.responseJson(resp), "error")
  } catch {
  | JsExn(_) => None
  }
  reason->Option.mapOr(said, r => said ++ ": " ++ r)
}

let decodeHaulResponse = async (resp: WebApi.response): result<Types.haulStatus, string> =>
  if WebApi.responseOk(resp) {
    switch Shared.decodeHaulStatus(await WebApi.responseJson(resp)) {
    | Ok(status) => Ok(status)
    | Error(msg) => Error("could not read the haul: " ++ msg)
    }
  } else {
    Error(await readErrorReason(resp))
  }

let postHaul = async (storeName: string): result<Types.haulStatus, string> =>
  try {
    let body = storeName == "" ? "" : JSON.stringify(Json.obj([("name", Json.str(storeName))]))
    let resp = await WebApi.fetchString(
      "/api/hauls",
      {
        WebApi.method: "POST",
        headers: Dict.fromArray([("Content-Type", "application/json")]),
        body,
      },
    )
    await decodeHaulResponse(resp)
  } catch {
  | JsExn(_) => Error("could not reach the server")
  }

let getHaulStatus = async (haulId: string): result<Types.haulStatus, string> =>
  try {
    let resp = await WebApi.fetchGet("/api/hauls/" ++ haulId)
    await decodeHaulResponse(resp)
  } catch {
  | JsExn(_) => Error("could not reach the server")
  }

let postHaulDone = async (haulId: string): result<Types.haulStatus, string> =>
  try {
    let resp = await WebApi.fetchString(
      "/api/hauls/" ++ haulId ++ "/done",
      {WebApi.method: "POST", headers: Dict.make(), body: ""},
    )
    await decodeHaulResponse(resp)
  } catch {
  | JsExn(_) => Error("could not reach the server")
  }

// A 200 whose "place" key doesn't decode still counts as sent — the outbox
// entry is done either way, per R5. Sent(None) tells the caller there's no
// fresh place to show, not that the send failed.
type placeResult = Sent(option<Types.place>) | Rejected(int) | NotSent(string)

let postPlace = async (haulId: string, body: string): placeResult =>
  try {
    let resp = await WebApi.fetchString(
      "/api/hauls/" ++ haulId ++ "/place",
      {
        WebApi.method: "POST",
        headers: Dict.fromArray([("Content-Type", "application/json")]),
        body,
      },
    )
    if WebApi.responseOk(resp) {
      let json = await WebApi.responseJson(resp)
      Sent(Json.field(json, "place")->Option.flatMap(Shared.decodePlace))
    } else {
      let status = WebApi.responseStatus(resp)
      if status == 400 || status == 404 {
        Rejected(status)
      } else {
        NotSent(await readErrorReason(resp))
      }
    }
  } catch {
  | JsExn(_) => NotSent("could not reach the server")
  }

// Posts one queued photo. The brain answers 202 with {"sceneId", ...} and,
// for a client id it has already seen, "duplicate": true — a retried
// upload then costs nothing.
// The stored photo of a scene (docs/spec-haul-mode.md "The routes",
// GET /api/scenes/:id/photo). A plain string build, not a fetch — the page
// hands this straight to an <img src> or a CSS background-image.
let scenePhotoUrl = (sceneId: string): string =>
  "/api/scenes/" ++ encodeURIComponent(sceneId) ++ "/photo"

// XMLHttpRequest, not fetch: the only way to get a real upload-progress
// callback (bytes sent so far) that also works in Safari/iOS Safari.
// docs/spec-upload-progress.md's Research section has why.
let postHaulScene = (
  haulId: string,
  clientId: string,
  blob: WebApi.blob,
  ~onProgress: int => unit,
): promise<result<(string, bool), string>> =>
  Promise.make((resolve, _reject) => {
    let req = WebApi.makeXhr()
    WebApi.xhrOpen(req, "POST", "/api/hauls/" ++ haulId ++ "/scenes")
    WebApi.xhrSetRequestHeader(req, "Content-Type", "image/jpeg")
    WebApi.xhrSetRequestHeader(req, "x-client-id", clientId)
    WebApi.onUploadProgress(WebApi.xhrUploadOf(req), evt =>
      onProgress(evt.lengthComputable ? Float.toInt(evt.loaded) : 0)
    )
    WebApi.onXhrError(req, () => resolve(Error("could not reach the server")))
    WebApi.onXhrLoad(req, () => {
      let status = WebApi.xhrStatus(req)
      let text = WebApi.xhrResponseText(req)
      let json = try Some(JSON.parseOrThrow(text)) catch {
      | JsExn(_) => None
      }
      if status >= 200 && status < 300 {
        switch json->Option.flatMap(j => Json.stringField(j, "sceneId")) {
        | Some(sceneId) =>
          resolve(Ok((sceneId, json->Option.flatMap(j => Json.boolField(j, "duplicate"))->Option.getOr(false))))
        | None => resolve(Error("could not read the reply: missing sceneId"))
        }
      } else {
        let said = "the server said " ++ Int.toString(status)
        let reason = json->Option.flatMap(j => Json.stringField(j, "error"))
        resolve(Error(reason->Option.mapOr(said, r => said ++ ": " ++ r)))
      }
    })
    WebApi.xhrSend(req, blob)
  })
