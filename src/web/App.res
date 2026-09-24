// The phone page. Top to bottom: model picker, long-edge picker, take-photo
// button, status line, item list, footer. TEA via useReducer — this file
// holds the view and the effect orchestrator; AppState.res holds the pure
// model/msg/update.

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

// The side-effect edge: called from the file input's onChange, never from
// update/view. Dispatches a msg after each step so `update` stays pure.
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

let statusText = (status: AppState.status): string =>
  switch status {
  | Idle => ""
  | Resizing => "resizing"
  | Uploading => "uploading"
  | Waiting => "waiting"
  | ErrorStatus(msg) => msg
  }

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

module ItemCard = {
  @react.component
  let make = (~item: Types.replyItem) =>
    <li className="item">
      <div className="item-name"> {React.string(item.name)} </div>
      <div className="item-range">
        {React.string(fmtUsd(item.estimateLowUsd) ++ " – " ++ fmtUsd(item.estimateHighUsd))}
      </div>
      <div className="item-confidence">
        {React.string("confidence " ++ fmtPct(item.confidence))}
      </div>
      <div className="item-basis"> {React.string(item.basis)} </div>
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
      {switch reply.ebayNote {
      | Some(note) => <div className="ebay-note"> {React.string(note)} </div>
      | None => React.null
      }}
    </footer>
}

@react.component
let make = () => {
  let (model, dispatch) = React.useReducer(AppState.update, AppState.initialModel)

  let onFileChange = (event: ReactEvent.Form.t) => {
    let target = WebApi.eventTarget(event)
    switch WebApi.targetFiles(target)->Nullable.toOption {
    | None => ()
    | Some(files) =>
      if WebApi.fileListLength(files) > 0 {
        switch WebApi.fileListItem(files, 0)->Nullable.toOption {
        | None => ()
        | Some(file) =>
          runPhotoFlow(
            dispatch,
            Shared.modelId(model.selectedModel),
            model.longEdge,
            file,
          )->Promise.ignore
        }
      }
    }
  }

  let onModelChange = (event: ReactEvent.Form.t) => {
    let value = WebApi.targetValue(WebApi.eventTarget(event))
    switch Shared.parseModelId(value) {
    | Some(m) => dispatch(AppState.SetModel(m))
    | None => ()
    }
  }

  let onLongEdgeChange = (event: ReactEvent.Form.t) => {
    let value = WebApi.targetValue(WebApi.eventTarget(event))
    switch Int.fromString(value) {
    | Some(n) => dispatch(AppState.SetLongEdge(n))
    | None => ()
    }
  }

  <div className="page">
    <h1> {React.string("reflip")} </h1>
    <div className="pickers">
      <label className="picker">
        {React.string("Model")}
        <select value={Shared.modelId(model.selectedModel)} onChange={onModelChange}>
          {Shared.allModels
          ->Array.map(m =>
            <option key={Shared.modelId(m)} value={Shared.modelId(m)}>
              {React.string(Shared.modelLabel(m))}
            </option>
          )
          ->React.array}
        </select>
      </label>
      <label className="picker">
        {React.string("Long edge")}
        <select value={Int.toString(model.longEdge)} onChange={onLongEdgeChange}>
          <option value="1568"> {React.string("1568 px (default)")} </option>
          <option value="2576"> {React.string("2576 px")} </option>
        </select>
      </label>
    </div>
    <label className="take-photo">
      <input
        className="visually-hidden"
        type_="file"
        accept="image/*"
        capture=#environment
        onChange={onFileChange}
      />
      {React.string("Take photo")}
    </label>
    <div className="status"> {React.string(statusText(model.status))} </div>
    {switch model.reply {
    | None => React.null
    | Some(reply) =>
      <ul className="items">
        {reply.items
        ->Array.mapWithIndex((item, i) => <ItemCard key={Int.toString(i)} item />)
        ->React.array}
      </ul>
    }}
    {switch model.reply {
    | None => React.null
    | Some(reply) => <Footer model reply />
    }}
  </div>
}
