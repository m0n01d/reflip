// The Map view (docs/spec-haul-map.md "The map", "The code", "The page"):
// the Leaflet map, the range chips, the list of hauls and the panel for
// the selected haul. Pure over MapState.model; every control dispatches a
// MapState.msg. App.res owns the network side effects (loading the list,
// sending a Set place tap) by watching this model's fields.

let fmtUsd = (n: float): string => "$" ++ Float.toFixed(n, ~digits=2)

let containerId = "haul-map-canvas"

let osmAttribution = "&copy; <a href=\"https://www.openstreetmap.org/copyright\" target=\"_blank\" rel=\"noopener\">OpenStreetMap</a> contributors"

let leafletOptionsOf = (style: MapState.pinStyle): Leaflet.circleMarkerOptions => {
  radius: style.radius,
  color: "#FF6A13",
  fillColor: "#FF6A13",
  fillOpacity: style.filled ? 0.85 : 0.0,
  weight: 2.0,
  fill: style.filled,
}

let haulTitle = (h: Types.haulListRow): string => {
  let name = h.name->Option.getOr("")->String.trim
  name == "" ? "Haul" : name
}

@react.component
let make = (~model: MapState.model, ~dispatch: MapState.msg => unit) => {
  let mapRef: React.ref<option<Leaflet.map>> = React.useRef(None)
  let groupRef: React.ref<option<Leaflet.layerGroup>> = React.useRef(None)

  // -- make the map when this view opens, remove it when it closes -------
  // MapView only exists in the tree while AppState.MapTab is active, so
  // mount/unmount here is exactly "the view opens"/"the view closes".
  React.useEffect0(() => {
    let m = Leaflet.map(containerId)
    Leaflet.setView(m, (20.0, 0.0), 2)
    let tiles = Leaflet.tileLayer(
      "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
      {attribution: osmAttribution},
    )
    Leaflet.addTileLayerTo(tiles, m)
    let group = Leaflet.layerGroup()
    Leaflet.addGroupTo(group, m)
    Leaflet.onMapClick(m, "click", event =>
      dispatch(MapState.MapTapped(event["latlng"]["lat"], event["latlng"]["lng"]))
    )
    mapRef.current = Some(m)
    groupRef.current = Some(group)
    // A container sized entirely by CSS should already have its final size
    // on the first paint, but a fresh web-font swap can still land a tick
    // late — invalidateSize once, after layout settles, is the standard
    // Leaflet fix for tiles that come up misaligned.
    let tid = WebApi.setTimeout(() => Leaflet.invalidateSize(m), 0)
    Some(
      () => {
        WebApi.clearTimeout(tid)
        Leaflet.remove(m)
        mapRef.current = None
        groupRef.current = None
      },
    )
  })

  // -- redraw the pins when the hauls, the range or the selection change --
  React.useEffect3(() => {
    switch (mapRef.current, groupRef.current) {
    | (Some(m), Some(group)) =>
      let nowMs = Date.now()
      let placed =
        MapState.filterByRange(model.hauls, model.range, ~nowMs)->Array.filter(h =>
          h.place->Option.isSome
        )
      Leaflet.clearLayers(group)
      placed->Array.forEach(h =>
        switch h.place {
        | None => ()
        | Some(place) =>
          let hasBuys = Array.length(h.buys) > 0
          let selected = model.selected == Some(h.haulId)
          let marker = Leaflet.circleMarker(
            (place.lat, place.lon),
            leafletOptionsOf(MapState.pinStyleFor(~hasBuys, ~selected=false)),
          )
          if selected {
            Leaflet.setMarkerStyle(marker, leafletOptionsOf(MapState.pinStyleFor(~hasBuys, ~selected=true)))
          }
          Leaflet.onMarkerClick(marker, "click", _event => dispatch(MapState.HaulSelected(h.haulId)))
          Leaflet.addMarkerTo(marker, group)
        }
      )
      switch MapState.fitRuleFor(MapState.pointsOf(placed)) {
      | FitWorld => Leaflet.setView(m, (20.0, 0.0), 2)
      | FitOne(lat, lon) => Leaflet.setView(m, (lat, lon), 15)
      | FitBounds(points) => Leaflet.fitBounds(m, points, {padding: (40.0, 40.0)})
      }
    | _ => ()
    }
    None
  }, (model.hauls, model.range, model.selected))

  let nowMs = Date.now()
  let filtered = MapState.filterByRange(model.hauls, model.range, ~nowMs)
  let selectedHaul = model.selected->Option.flatMap(id => model.hauls->Array.find(h => h.haulId == id))

  <div className="haul-map-view">
    <div role="group" ariaLabel="Range" className="haul-map-chips">
      {MapState.allRanges
      ->Array.map(r => {
        let active = model.range == r
        <button
          key={MapState.rangeLabel(r)}
          type_="button"
          ariaPressed={active ? #"true" : #"false"}
          className={"haul-map-chip" ++ (active ? " haul-map-chip-active" : "")}
          onClick={_ => dispatch(MapState.RangeSelected(r))}>
          {React.string(MapState.rangeLabel(r))}
        </button>
      })
      ->React.array}
    </div>
    <div className="haul-map-canvas-wrap">
      <div id=containerId className="haul-map-canvas" />
    </div>
    {switch model.load {
    | NotLoaded | Loading => <div className="haul-map-status"> {React.string("Loading hauls…")} </div>
    | LoadFailed(reason) => <div className="haul-map-status haul-map-error"> {React.string(reason)} </div>
    | Loaded => React.null
    }}
    <ul className="haul-map-list">
      {filtered
      ->Array.map(h => {
        let active = model.selected == Some(h.haulId)
        <li key={h.haulId}>
          <button
            type_="button"
            className={"haul-map-row" ++ (active ? " haul-map-row-active" : "")}
            onClick={_ => dispatch(MapState.HaulSelected(h.haulId))}>
            <span className="haul-map-row-name"> {React.string(haulTitle(h))} </span>
            <span className="haul-map-row-date"> {React.string(HaulLayout.stampDateOf(h.startedAt))} </span>
            <span className="haul-map-row-place">
              {React.string(h.place->Option.isSome ? "" : "No place")}
            </span>
          </button>
        </li>
      })
      ->React.array}
    </ul>
    {switch selectedHaul {
    | None => React.null
    | Some(h) =>
      <section className="haul-map-panel">
        <div className="haul-map-panel-head">
          <span className="haul-map-panel-name"> {React.string(haulTitle(h))} </span>
          <span className="haul-map-panel-date">
            {React.string(HaulLayout.stampDateOf(h.startedAt) ++ " · " ++ HaulLayout.timeOf(h.startedAt))}
          </span>
        </div>
        <div className="haul-map-panel-counts">
          {React.string(
            Int.toString(h.photoCount) ++
            (h.photoCount == 1 ? " photo · " : " photos · ") ++
            Int.toString(h.gemCount) ++
            (h.gemCount == 1 ? " gem" : " gems"),
          )}
        </div>
        {Array.length(h.buys) > 0
          ? <>
              <ul className="haul-map-buys">
                {h.buys
                ->Array.mapWithIndex((b, i) =>
                  <li key={Int.toString(i)} className="haul-map-buy">
                    <span className="haul-map-buy-name"> {React.string(b.name)} </span>
                    <span className="haul-map-buy-price">
                      {React.string(
                        fmtUsd(b.paidUsd) ++
                        switch b.soldUsd {
                        | Some(sold) => " → sold " ++ fmtUsd(sold)
                        | None => ""
                        },
                      )}
                    </span>
                  </li>
                )
                ->React.array}
              </ul>
              <div className="haul-map-panel-total">
                {React.string("Total paid " ++ fmtUsd(h.paidUsd))}
              </div>
            </>
          : React.null}
        {switch model.setPlace {
        | Selecting(id) if id == h.haulId =>
          <div className="haul-map-place-hint">
            <span> {React.string("Tap the map to set the place.")} </span>
            <button
              type_="button"
              className="haul-place-retry"
              onClick={_ => dispatch(MapState.SetPlaceCancelled)}>
              {React.string("Cancel")}
            </button>
          </div>
        | Submitting(id, _, _) if id == h.haulId =>
          <div className="haul-map-place-hint"> {React.string("Saving the place…")} </div>
        | _ =>
          <button
            type_="button"
            className="haul-map-set-place"
            onClick={_ => dispatch(MapState.SetPlaceTapped(h.haulId))}>
            {React.string("Set place")}
          </button>
        }}
        {switch model.placeError {
        | Some(reason) => <div className="haul-map-error"> {React.string(reason)} </div>
        | None => React.null
        }}
      </section>
    }}
  </div>
}
