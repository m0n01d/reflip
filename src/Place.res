// A haul's place: the point the phone or the map page reports for it. Per
// docs/spec-haul-map.md "Shape > The brain" — pure, no Node imports, depends
// only on Types.res so both Store.res and Shared.res can reuse it.

type input = {
  lat: float,
  lon: float,
  accuracyM: option<float>,
  source: Types.placeSource,
}

let sourceToString = (source: Types.placeSource): string =>
  switch source {
  | Gps => "gps"
  | Pin => "pin"
  }

let sourceFromString = (s: string): option<Types.placeSource> =>
  switch s {
  | "gps" => Some(Gps)
  | "pin" => Some(Pin)
  | _ => None
  }

// lat/lon/source are required. lat is [-90,90], lon is [-180,180], both
// inclusive. accuracyM is 0 or more, or null for a pin — a missing or
// non-numeric accuracyM behaves the same as absent, which is an error for a
// gps place and Ok(None) for a pin.
let decodeInput = (json: JSON.t): result<input, string> =>
  switch (
    Json.floatField(json, "lat"),
    Json.floatField(json, "lon"),
    Json.stringField(json, "source"),
  ) {
  | (Some(lat), Some(lon), Some(sourceStr)) =>
    switch sourceFromString(sourceStr) {
    | None => Error("source must be \"gps\" or \"pin\"")
    | Some(source) =>
      if lat < -90.0 || lat > 90.0 {
        Error("lat must be between -90 and 90")
      } else if lon < -180.0 || lon > 180.0 {
        Error("lon must be between -180 and 180")
      } else {
        switch Json.floatField(json, "accuracyM") {
        | Some(a) if a < 0.0 => Error("accuracyM must be 0 or more")
        | Some(a) => Ok({lat, lon, accuracyM: Some(a), source})
        | None =>
          switch source {
          | Gps => Error("gps place needs accuracyM")
          | Pin => Ok({lat, lon, accuracyM: None, source})
          }
        }
      }
    }
  | _ => Error("lat, lon and source are required")
  }

// A gps fix never overwrites a pin the person dropped by hand. Any other
// combination takes the incoming place.
let choose = (~stored: option<Types.place>, ~incoming: Types.place): Types.place =>
  switch (stored, incoming.source) {
  | (Some({source: Pin} as pin), Gps) => pin
  | _ => incoming
  }
