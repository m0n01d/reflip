// MapState.res: the pure range filter, pin style and fit rule, plus a
// couple of update transitions (docs/spec-haul-map.md "The code").

let haulAt = (~haulId: string, ~startedAt: string, ~place: option<Types.place>): Types.haulListRow => {
  haulId,
  name: None,
  startedAt,
  place,
  photoCount: 1,
  gemCount: 0,
  paidUsd: 0.0,
  buys: [],
}

let places: Types.place = {lat: 47.0, lon: -122.0, accuracyM: Some(5.0), source: Gps, at: ""}

let run = () => {
  TestKit.section("MapState.filterByRange")

  // 2026-09-26T00:00:00Z, in ms.
  let nowMs = 1790380800000.0

  TestKit.check(
    "a haul from 10 days ago is inside the 30-day range",
    MapState.inRange("2026-09-16T00:00:00.000Z", MapState.Days30, ~nowMs),
  )
  TestKit.check(
    "a haul from 40 days ago is outside the 30-day range",
    !MapState.inRange("2026-08-17T00:00:00.000Z", MapState.Days30, ~nowMs),
  )
  TestKit.check(
    "a haul from a few months ago is inside the 1-year range",
    MapState.inRange("2026-06-01T00:00:00.000Z", MapState.Year1, ~nowMs),
  )
  TestKit.check(
    "a haul from 2 years ago is outside the 1-year range",
    !MapState.inRange("2024-09-01T00:00:00.000Z", MapState.Year1, ~nowMs),
  )
  TestKit.check(
    "the All range keeps a haul from any date",
    MapState.inRange("2020-01-01T00:00:00.000Z", MapState.All, ~nowMs),
  )
  TestKit.check(
    "a startedAt that does not parse is out of every range but All",
    !MapState.inRange("not a date", MapState.Days90, ~nowMs),
  )

  let hauls = [
    haulAt(~haulId="new", ~startedAt="2026-09-25T00:00:00.000Z", ~place=Some(places)),
    haulAt(~haulId="old", ~startedAt="2024-01-01T00:00:00.000Z", ~place=None),
  ]
  let filtered = MapState.filterByRange(hauls, MapState.Days90, ~nowMs)
  TestKit.check("filterByRange keeps the haul inside the range", filtered->Array.some(h => h.haulId == "new"))
  TestKit.check(
    "filterByRange drops the haul outside the range",
    !(filtered->Array.some(h => h.haulId == "old")),
  )

  TestKit.section("MapState.pinStyleFor")

  TestKit.check(
    "a haul with a buy gets a filled pin",
    MapState.pinStyleFor(~hasBuys=true, ~selected=false).filled,
  )
  TestKit.check(
    "a haul with no buy gets a hollow pin",
    !MapState.pinStyleFor(~hasBuys=false, ~selected=false).filled,
  )
  TestKit.check(
    "the selected pin is larger than the unselected pin",
    MapState.pinStyleFor(~hasBuys=false, ~selected=true).radius >
      MapState.pinStyleFor(~hasBuys=false, ~selected=false).radius,
  )

  TestKit.section("MapState.fitRuleFor")

  TestKit.check(
    "no pins fits the whole world",
    switch MapState.fitRuleFor([]) {
    | FitWorld => true
    | _ => false
    },
  )
  TestKit.check(
    "one pin fits at zoom 15 on that point",
    switch MapState.fitRuleFor([(47.0, -122.0)]) {
    | FitOne(47.0, -122.0) => true
    | _ => false
    },
  )
  TestKit.check(
    "two or more pins fit their bounds",
    switch MapState.fitRuleFor([(47.0, -122.0), (48.0, -121.0)]) {
    | FitBounds([(47.0, -122.0), (48.0, -121.0)]) => true
    | _ => false
    },
  )

  TestKit.section("MapState.pointsOf")

  TestKit.check(
    "pointsOf reads only the hauls that have a place",
    MapState.pointsOf(hauls) == [(47.0, -122.0)],
  )

  TestKit.section("MapState.pinPlaceBody")

  TestKit.check(
    "pinPlaceBody encodes a pin place with a null accuracy",
    MapState.pinPlaceBody(47.5, -122.5) ==
      "{\"lat\":47.5,\"lon\":-122.5,\"accuracyM\":null,\"source\":\"pin\"}",
  )

  TestKit.section("MapState.update")

  let m0 = MapState.initialModel
  let m1 = MapState.update(m0, MapState.HaulsLoaded(hauls))
  TestKit.check("HaulsLoaded stores the hauls and marks Loaded", switch m1.load {
  | Loaded => Array.length(m1.hauls) == 2
  | _ => false
  })

  let m2 = MapState.update(m1, MapState.SetPlaceTapped("new"))
  TestKit.check(
    "SetPlaceTapped enters Selecting for that haul",
    switch m2.setPlace {
    | Selecting("new") => true
    | _ => false
    },
  )

  let m3 = MapState.update(m2, MapState.MapTapped(1.0, 2.0))
  TestKit.check(
    "a map tap while Selecting moves to Submitting with the tapped point",
    switch m3.setPlace {
    | Submitting("new", 1.0, 2.0) => true
    | _ => false
    },
  )

  let m4 = MapState.update(m3, MapState.PlaceSet)
  TestKit.check("PlaceSet returns to Off", m4.setPlace == MapState.Off)

  let m5 = MapState.update(m3, MapState.PlaceSetFailed("could not reach the server"))
  TestKit.check(
    "PlaceSetFailed from Submitting returns to Selecting with the reason kept",
    switch m5.setPlace {
    | Selecting("new") => m5.placeError == Some("could not reach the server")
    | _ => false
    },
  )

  let m6 = MapState.update(m1, MapState.MapTapped(1.0, 2.0))
  TestKit.check("a map tap while Off does nothing", m6.setPlace == MapState.Off)
}
