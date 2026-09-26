// The page chrome around the scan flow (docs/design/scan-ui/Main.dc.html):
// the header (logo, plus settings / LIVE+Stop / New scan depending on
// phase), the Scan|Haul mode switch, the Ready screen, the Settings sheet,
// and — once a run starts — ScanView for everything below the header.
//
// Pure view over AppState.model; every control dispatches AppState.msg
// (wrapping ScanState.msg for the scan sub-model via the Scan constructor).
// The three callbacks below are effects that must stay defined in App.res
// (file input handling with refs, and the haul POST) — passed down rather
// than duplicated here, so App.res owns every side effect.

@react.component
let make = (
  ~model: AppState.model,
  ~dispatch: AppState.msg => unit,
  ~onScanFileChange: ReactEvent.Form.t => unit,
  ~onStoreNameChange: ReactEvent.Form.t => unit,
  ~onStartHaul: ReactEvent.Mouse.t => unit,
) => {
  let scanDispatch = (m: ScanState.msg) => dispatch(AppState.Scan(m))
  let phase = model.scan.phase
  let isReady = phase == ScanState.Ready
  let onScanTab = _ => dispatch(AppState.SetActiveTab(AppState.ScanTab))
  let onHaulTab = _ => dispatch(AppState.SetActiveTab(AppState.HaulTab))
  let openSettings = _ => dispatch(AppState.SetSettingsOpen(true))
  let closeSettings = _ => dispatch(AppState.SetSettingsOpen(false))
  let onStop = (_: ReactEvent.Mouse.t) => scanDispatch(ScanState.StopTapped)
  let onNewScan = (_: ReactEvent.Mouse.t) => scanDispatch(ScanState.NewScan)

  // Shared.modelLabel spells out "Sonnet 5 (the default)" for the settings
  // API; the design's chip wants the short form (Ready.png). ScanState
  // already has this exact switch (the run receipt's Model row uses it),
  // so reuse it here instead of keeping a second copy in sync (R8).
  let modelChipLabel = ScanState.shortModelLabel(model.selectedModel)

  <div className="scan-shell">
    <header className="scan-header">
      <div className="scan-header-logo">
        <span ariaHidden={true} className="scan-header-dot" />
        <span className="scan-header-word"> {React.string("reflip")} </span>
      </div>
      <div className="scan-header-actions">
        {if isReady {
          <button
            type_="button" ariaLabel="Settings" onClick={openSettings} className="scan-icon-btn">
            <svg
              width="24"
              height="24"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              ariaHidden={true}>
              <path d="M4 7h10M18 7h2M4 17h4M12 17h8" />
              <circle cx="16" cy="7" r="2" />
              <circle cx="10" cy="17" r="2" />
            </svg>
          </button>
        } else {
          switch phase {
          | ScanState.Sending | ScanState.Live =>
            let reconnecting = ScanState.connectionState(model.scan) == ScanState.Reconnecting
            <>
              <span className="scan-live">
                <span
                  ariaHidden={true}
                  className={"scan-live-dot" ++ (reconnecting ? " scan-live-dot-muted" : "")}
                />
                {React.string(reconnecting ? "RECONNECTING" : "LIVE")}
              </span>
              <button type_="button" onClick={onStop} className="scan-pill-btn">
                {React.string("Stop")}
              </button>
            </>
          | ScanState.Ended(_) =>
            <button type_="button" onClick={onNewScan} className="scan-pill-btn">
              {React.string("New scan")}
            </button>
          | ScanState.Ready => React.null
          }
        }}
      </div>
    </header>
    {if isReady {
      <>
        <div role="group" ariaLabel="Mode" className="scan-mode-switch">
          <button
            type_="button"
            ariaPressed={model.activeTab == AppState.ScanTab ? #"true" : #"false"}
            onClick={onScanTab}
            className={"scan-mode-btn" ++
            (model.activeTab == AppState.ScanTab ? " scan-mode-btn-active" : "")}>
            {React.string("Scan")}
          </button>
          <button
            type_="button"
            ariaPressed={model.activeTab == AppState.HaulTab ? #"true" : #"false"}
            onClick={onHaulTab}
            className={"scan-mode-btn" ++
            (model.activeTab == AppState.HaulTab ? " scan-mode-btn-active" : "")}>
            {React.string("Haul")}
          </button>
        </div>
        {switch model.activeTab {
        | AppState.ScanTab =>
          <div className="scan-ready">
            <h1 className="scan-ready-title"> {React.string("What's on the table?")} </h1>
            <p className="scan-ready-sub">
              {React.string("Snap it. Price stickers land on the photo as each item is found.")}
            </p>
            {switch model.status {
            | AppState.ErrorStatus(msg) => <div className="scan-ready-error"> {React.string(msg)} </div>
            | AppState.Idle | AppState.Resizing | AppState.Uploading | AppState.Waiting => React.null
            }}
            <div className="scan-ready-actions">
              <label className="scan-snap-btn">
                <input
                  type_="file"
                  accept="image/*"
                  capture=#environment
                  onChange={onScanFileChange}
                  className="scan-file-input"
                />
                <span ariaHidden={true} className="scan-snap-ring" />
                <span className="scan-snap-inner">
                  <svg
                    width="46"
                    height="46"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="1.8"
                    strokeLinejoin="round"
                    ariaHidden={true}>
                    <path
                      d="M3 8.5A1.5 1.5 0 0 1 4.5 7h2.6l1.6-2.2h6.6L16.9 7h2.6A1.5 1.5 0 0 1 21 8.5v9A1.5 1.5 0 0 1 19.5 19h-15A1.5 1.5 0 0 1 3 17.5z"
                    />
                    <circle cx="12" cy="13" r="3.6" />
                  </svg>
                  <span className="scan-snap-label"> {React.string("Snap a photo")} </span>
                </span>
              </label>
              <label className="scan-pick-link">
                <input
                  type_="file"
                  accept="image/*"
                  onChange={onScanFileChange}
                  className="scan-file-input"
                />
                {React.string("or pick from your photos")}
              </label>
            </div>
            <div className="scan-settings-chip-row">
              <button type_="button" onClick={openSettings} className="scan-settings-chip">
                <svg
                  width="16"
                  height="16"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                  ariaHidden={true}>
                  <path d="M4 7h10M18 7h2M4 17h4M12 17h8" />
                  <circle cx="16" cy="7" r="2" />
                  <circle cx="10" cy="17" r="2" />
                </svg>
                <span>
                  {React.string(modelChipLabel ++ " · " ++ Int.toString(model.longEdge) ++ " px")}
                </span>
              </button>
            </div>
          </div>
        | AppState.HaulTab =>
          // Unchanged from the original inline markup — same classNames,
          // same behavior. Only its visibility (now gated behind the Haul
          // tab instead of always-on) changed.
          <section className="haul-start">
            <h2> {React.string("Haul mode")} </h2>
            <input
              className="store-name"
              type_="text"
              placeholder="Store name (optional)"
              value={model.storeName}
              onChange={onStoreNameChange}
            />
            <button className="take-photo" onClick={onStartHaul}>
              {React.string("Start haul")}
            </button>
            {switch model.haulError {
            | Some(msg) => <div className="haul-error"> {React.string(msg)} </div>
            | None => React.null
            }}
          </section>
        }}
      </>
    } else {
      <ScanView model={model.scan} dispatch={scanDispatch} onNewPhoto={onScanFileChange} />
    }}
    {switch model.settingsOpen {
    | false => React.null
    | true =>
      <>
        <button
          type_="button"
          ariaLabel="Close settings"
          tabIndex={-1}
          onClick={closeSettings}
          className="scan-sheet-backdrop"
        />
        <section
          role="dialog" ariaModal={true} ariaLabel="Settings" className="scan-sheet-panel">
          <div className="scan-sheet-grabber-row">
            <span ariaHidden={true} className="scan-sheet-grabber" />
          </div>
          <div className="scan-settings-sheet">
            <div className="scan-settings-head">
              <h2 className="scan-settings-title"> {React.string("Settings")} </h2>
              <button type_="button" onClick={closeSettings} className="scan-settings-done">
                {React.string("Done")}
              </button>
            </div>
            <fieldset className="scan-fieldset">
              <legend className="scan-legend"> {React.string("MODEL")} </legend>
              {ScanState.settingsModelOrder
              ->Array.map(m => {
                let (label, desc) = switch m {
                | Shared.Sonnet5 => (
                    "Sonnet 5",
                    "Default. On 10 real scenes: median 0:47 and $0.15 a photo.",
                  )
                | Shared.Opus5_5 => ("Opus 5.5", "Most capable. Twice the token price of Sonnet 5.")
                | Shared.Haiku4_5 => (
                    "Haiku 4.5",
                    "Half the token price of Sonnet 5. Sees at most 1568 px.",
                  )
                }
                <label key={Shared.modelId(m)} className="scan-option">
                  <input
                    type_="radio"
                    name="scan-settings-model"
                    checked={model.selectedModel == m}
                    onChange={_ => dispatch(AppState.SetModel(m))}
                    className="scan-option-radio"
                  />
                  <span>
                    <span className="scan-option-label"> {React.string(label)} </span>
                    <span className="scan-option-desc"> {React.string(desc)} </span>
                  </span>
                </label>
              })
              ->React.array}
            </fieldset>
            <fieldset className="scan-fieldset">
              <legend className="scan-legend"> {React.string("PHOTO SIZE")} </legend>
              {[
                (1568, "1568 px", "Default. About 2,400 image tokens."),
                (
                  2576,
                  "2576 px",
                  "Sharper. About 6,300 image tokens, near $0.01 more a photo on Sonnet 5.",
                ),
              ]
              ->Array.map(((px, label, desc)) =>
                <label key={Int.toString(px)} className="scan-option">
                  <input
                    type_="radio"
                    name="scan-settings-edge"
                    checked={model.longEdge == px}
                    onChange={_ => dispatch(AppState.SetLongEdge(px))}
                    className="scan-option-radio"
                  />
                  <span>
                    <span className="scan-option-label"> {React.string(label)} </span>
                    <span className="scan-option-desc"> {React.string(desc)} </span>
                  </span>
                </label>
              )
              ->React.array}
            </fieldset>
          </div>
        </section>
      </>
    }}
  </div>
}
