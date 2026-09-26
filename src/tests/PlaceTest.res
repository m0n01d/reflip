// Place.decodeInput and Place.choose: one test for each case in
// docs/haul-map-build.md's design notes for step 2.

let run = () => {
  TestKit.section("Place.decodeInput")

  TestKit.check(
    "lat=90 with a pin and a null accuracyM is valid",
    switch Place.decodeInput(
      Json.obj([("lat", Json.num(90.0)), ("lon", Json.num(0.0)), ("source", Json.str("pin"))]),
    ) {
    | Ok({lat: 90.0, lon: 0.0, accuracyM: None, source: Pin}) => true
    | _ => false
    },
  )

  TestKit.check(
    "lat=90.0001 is invalid",
    switch Place.decodeInput(
      Json.obj([
        ("lat", Json.num(90.0001)),
        ("lon", Json.num(0.0)),
        ("source", Json.str("pin")),
      ]),
    ) {
    | Error(_) => true
    | Ok(_) => false
    },
  )

  TestKit.check(
    "lon=-180 is valid",
    switch Place.decodeInput(
      Json.obj([("lat", Json.num(0.0)), ("lon", Json.num(-180.0)), ("source", Json.str("pin"))]),
    ) {
    | Ok(_) => true
    | Error(_) => false
    },
  )

  TestKit.check(
    "lon=-180.1 is invalid",
    switch Place.decodeInput(
      Json.obj([
        ("lat", Json.num(0.0)),
        ("lon", Json.num(-180.1)),
        ("source", Json.str("pin")),
      ]),
    ) {
    | Error(_) => true
    | Ok(_) => false
    },
  )

  TestKit.check(
    "a gps place with a null accuracyM is an error",
    switch Place.decodeInput(
      Json.obj([
        ("lat", Json.num(47.0)),
        ("lon", Json.num(-122.0)),
        ("source", Json.str("gps")),
        ("accuracyM", JSON.Encode.null),
      ]),
    ) {
    | Error(_) => true
    | Ok(_) => false
    },
  )

  TestKit.check(
    "a pin place with a null accuracyM is ok",
    switch Place.decodeInput(
      Json.obj([
        ("lat", Json.num(47.0)),
        ("lon", Json.num(-122.0)),
        ("source", Json.str("pin")),
        ("accuracyM", JSON.Encode.null),
      ]),
    ) {
    | Ok({accuracyM: None}) => true
    | _ => false
    },
  )

  TestKit.check(
    "accuracyM=-5 is an error",
    switch Place.decodeInput(
      Json.obj([
        ("lat", Json.num(47.0)),
        ("lon", Json.num(-122.0)),
        ("source", Json.str("gps")),
        ("accuracyM", Json.num(-5.0)),
      ]),
    ) {
    | Error(_) => true
    | Ok(_) => false
    },
  )

  TestKit.check(
    "lat as a JSON string is an error",
    switch Place.decodeInput(
      Json.obj([("lat", Json.str("47.0")), ("lon", Json.num(-122.0)), ("source", Json.str("gps"))]),
    ) {
    | Error(_) => true
    | Ok(_) => false
    },
  )

  TestKit.check(
    "source=\"wifi\" is an error",
    switch Place.decodeInput(
      Json.obj([("lat", Json.num(47.0)), ("lon", Json.num(-122.0)), ("source", Json.str("wifi"))]),
    ) {
    | Error(_) => true
    | Ok(_) => false
    },
  )

  TestKit.section("Place.choose")

  let gps = (): Types.place => {
    lat: 1.0,
    lon: 2.0,
    accuracyM: Some(5.0),
    source: Gps,
    at: "2026-09-26T00:00:00.000Z",
  }
  let pin = (): Types.place => {
    lat: 3.0,
    lon: 4.0,
    accuracyM: None,
    source: Pin,
    at: "2026-09-26T00:00:01.000Z",
  }

  TestKit.check(
    "no stored place: incoming gps wins",
    Place.choose(~stored=None, ~incoming=gps()) == gps(),
  )

  TestKit.check(
    "stored pin, incoming gps: the stored pin is kept",
    Place.choose(~stored=Some(pin()), ~incoming=gps()) == pin(),
  )

  TestKit.check(
    "stored gps, incoming pin: the incoming pin wins",
    Place.choose(~stored=Some(gps()), ~incoming=pin()) == pin(),
  )

  let newPin: Types.place = {
    lat: 9.0,
    lon: 9.0,
    accuracyM: None,
    source: Pin,
    at: "2026-09-26T00:00:02.000Z",
  }
  TestKit.check(
    "stored pin, incoming pin: the new pin wins",
    Place.choose(~stored=Some(pin()), ~incoming=newPin) == newPin,
  )
}
