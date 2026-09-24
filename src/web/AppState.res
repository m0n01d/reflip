// Model / Msg / update for the phone page — pure, no DOM, no Node. Side
// effects (resize, fetch) run in App.res's runPhotoFlow, which dispatches
// these msgs back in; update itself never touches the network or the
// canvas. src/tests/AppStateTest.res exercises this module directly.

type status = Idle | Resizing | Uploading | Waiting | ErrorStatus(string)

type model = {
  selectedModel: Shared.model,
  longEdge: int,
  status: status,
  reply: option<Types.sceneReply>,
  uploadBytes: option<int>,
  resizeMs: option<float>,
  rttMs: option<float>,
}

type msg =
  | SetModel(Shared.model)
  | SetLongEdge(int)
  | StartPhoto
  | ResizeOk(float, int)
  | ResizeErr(string)
  | UploadOk(Types.sceneReply, float)
  | UploadErr(string)
  | RttSent
  | RttErr(string)

let initialModel: model = {
  selectedModel: Shared.defaultModel,
  longEdge: 1568,
  status: Idle,
  reply: None,
  uploadBytes: None,
  resizeMs: None,
  rttMs: None,
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
    }
  | ResizeOk(resizeMs, uploadBytes) => {
      ...model,
      status: Uploading,
      resizeMs: Some(resizeMs),
      uploadBytes: Some(uploadBytes),
    }
  | ResizeErr(errMsg) => {...model, status: ErrorStatus(errMsg)}
  | UploadOk(reply, rttMs) => {...model, status: Waiting, reply: Some(reply), rttMs: Some(rttMs)}
  | UploadErr(errMsg) => {...model, status: ErrorStatus(errMsg)}
  | RttSent => {...model, status: Idle}
  | RttErr(errMsg) => {...model, status: ErrorStatus(errMsg)}
  }
