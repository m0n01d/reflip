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
