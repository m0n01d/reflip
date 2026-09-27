// The Map view's own model, msg and update (docs/spec-haul-map.md "The
// code": "The page stays TEA. A tap on a pin or on the map sends a msg.
// The model keeps the hauls, the range, the selected haul and the Set
// place mode."). Pure, no Node or DOM imports — MapView.res reads this
// model to draw the map and dispatches these msgs; App.res's effects call
// Api.res and dispatch the load/save results back in.

type range = Days30 | Days90 | Year1 | All

let allRanges = [Days30, Days90, Year1, All]

let rangeLabel = (range: range): string =>
  switch range {
  | Days30 => "30 days"
  | Days90 => "90 days"
  | Year1 => "1 year"
  | All => "All"
  }

type loadStatus = NotLoaded | Loading | Loaded | LoadFailed(string)

// Off: no Set place in progress. Selecting(haulId): the next map tap sets
// that haul's place. Submitting(haulId, lat, lon): a tap landed while
// selecting, and App.res's effect is sending it to the brain.
type setPlaceMode = Off | Selecting(string) | Submitting(string, float, float)

type model = {
  hauls: array<Types.haulListRow>,
  range: range,
  selected: option<string>, // the selected haul's haulId
  setPlace: setPlaceMode,
  load: loadStatus,
  placeError: option<string>,
}

let initialModel: model = {
  hauls: [],
  range: Days90,
  selected: None,
  setPlace: Off,
  load: NotLoaded,
  placeError: None,
}

type msg =
  | HaulsLoading
  | HaulsLoaded(array<Types.haulListRow>)
  | HaulsLoadFailed(string)
  | RangeSelected(range)
  | HaulSelected(string)
  | SetPlaceTapped(string)
  | SetPlaceCancelled
  | MapTapped(float, float)
  | PlaceSet
  | PlaceSetFailed(string)

let update = (model: model, msg: msg): model =>
  switch msg {
  | HaulsLoading => {...model, load: Loading}
  | HaulsLoaded(hauls) => {...model, hauls, load: Loaded}
  | HaulsLoadFailed(reason) => {...model, load: LoadFailed(reason)}
  | RangeSelected(range) => {...model, range}
  | HaulSelected(haulId) => {...model, selected: Some(haulId), setPlace: Off}
  | SetPlaceTapped(haulId) => {...model, setPlace: Selecting(haulId), placeError: None}
  | SetPlaceCancelled => {...model, setPlace: Off}
  | MapTapped(lat, lon) =>
    switch model.setPlace {
    | Selecting(haulId) => {...model, setPlace: Submitting(haulId, lat, lon)}
    | Off | Submitting(_) => model
    }
  | PlaceSet => {...model, setPlace: Off, placeError: None}
  | PlaceSetFailed(reason) =>
    switch model.setPlace {
    | Submitting(haulId, _, _) => {...model, setPlace: Selecting(haulId), placeError: Some(reason)}
    | Off | Selecting(_) => {...model, placeError: Some(reason)}
    }
  }

// -- pure helpers, each with its own test in MapStateTest.res --------------

let msPerDay = 24.0 *. 60.0 *. 60.0 *. 1000.0

// None means no cutoff (the All range).
let rangeCutoffMs = (range: range, ~nowMs: float): option<float> =>
  switch range {
  | Days30 => Some(nowMs -. 30.0 *. msPerDay)
  | Days90 => Some(nowMs -. 90.0 *. msPerDay)
  | Year1 => Some(nowMs -. 365.0 *. msPerDay)
  | All => None
  }

// A haul with a startedAt that does not parse is left out — it cannot be
// placed on a timeline, so it is safer to drop it than to guess it is in
// range.
let inRange = (startedAt: string, range: range, ~nowMs: float): bool =>
  switch rangeCutoffMs(range, ~nowMs) {
  | None => true
  | Some(cutoff) =>
    let t = Date.getTime(Date.fromString(startedAt))
    Float.isNaN(t) ? false : t >= cutoff
  }

let filterByRange = (
  hauls: array<Types.haulListRow>,
  range: range,
  ~nowMs: float,
): array<Types.haulListRow> => hauls->Array.filter(h => inRange(h.startedAt, range, ~nowMs))

// The lat/lon of every haul in the list that has a place, in the same
// order. Hauls with no place have no pin.
let pointsOf = (hauls: array<Types.haulListRow>): array<(float, float)> =>
  hauls->Array.filterMap(h => h.place->Option.map(p => (p.lat, p.lon)))

// docs/spec-haul-map.md "The map": "A haul with at least one buy gets a
// filled pin. A haul with no buy gets a hollow pin... The selected pin is
// larger."
type pinStyle = {radius: float, filled: bool}

let baseRadius = 8.0
let selectedRadius = 12.0

let pinStyleFor = (~hasBuys: bool, ~selected: bool): pinStyle => {
  radius: selected ? selectedRadius : baseRadius,
  filled: hasBuys,
}

// docs/spec-haul-map.md "The map": "The map fits the pins in the range,
// with 40 px of padding. With one pin, the zoom is 15. If no haul has a
// place, the map shows the whole world."
type fitRule = FitWorld | FitOne(float, float) | FitBounds(array<(float, float)>)

let fitRuleFor = (points: array<(float, float)>): fitRule =>
  switch points {
  | [] => FitWorld
  | [(lat, lon)] => FitOne(lat, lon)
  | many => FitBounds(many)
  }

// The Set place body for a map tap (docs/spec-haul-map.md "Shape":
// `POST /api/hauls/:id/place` with `{"lat", "lon", "accuracyM": null,
// "source": "pin"}`).
let pinPlaceBody = (lat: float, lon: float): string =>
  JSON.stringify(
    Json.obj([
      ("lat", Json.num(lat)),
      ("lon", Json.num(lon)),
      ("accuracyM", JSON.Encode.null),
      ("source", Json.str("pin")),
    ]),
  )
