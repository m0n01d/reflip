// Server: start on a free port with FIXTURES=1, POST a scene, check the
// reply shape and the new line in the log.

let run = async () => {
  TestKit.section("Server: fixture-mode POST /api/scene")

  let cwd = Node.Process.cwd()
  let dataDir = Node.Path.join([Node.Os.tmpdir(), "reflip-test-" ++ Node.Crypto.randomUUID()])
  let config: Config.t = {
    Config.port: 0,
    fixtures: true,
    dataDir,
    fixturesDir: Node.Path.join([cwd, "tests/fixtures"]),
    anthropicApiKey: None,
    ebayClientId: None,
    ebayClientSecret: None,
    structuredOutput: true,
    distIndexPath: Node.Path.join([cwd, "dist/index.html"]),
    distDir: Node.Path.join([cwd, "dist"]),
    haulConcurrency: 4,
    haulMaxUsd: 10.0,
    haulGemMinUsd: 20.0,
  }

  let {Server.server: server, port} = await Server.start(config)

  // Fixture mode never reads the request body for the Claude call — it
  // always loads tests/fixtures/claude-scene.json instead — but the size
  // now comes off the real bytes (JpegSize.res), so this POSTs the real
  // fixture photo. The brief's own curl verification does the same against
  // a live `npm start`.
  let photo = Node.Fs.readFileBuffer(Node.Path.join([cwd, "tests/fixtures/table.jpg"]))
  let resp = await Fetch.fetchBuffer(
    "http://127.0.0.1:" ++ Int.toString(port) ++ "/api/scene",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "image/jpeg")]),
      body: photo,
    },
  )
  TestKit.check("POST /api/scene responds 200", Fetch.status(resp) == 200)
  let json = await Fetch.json(resp)
  TestKit.check("reply has a sceneId", Json.stringField(json, "sceneId")->Option.isSome)
  TestKit.check("reply is marked fixture=true", Json.boolField(json, "fixture") == Some(true))
  TestKit.check(
    "reply's imageWidth/imageHeight match the real fixture photo (64x48)",
    Json.intField(json, "imageWidth") == Some(64) && Json.intField(json, "imageHeight") == Some(48),
  )
  let items = Json.arrayField(json, "items")->Option.getOr([])
  TestKit.check("reply has 3 items (fixture)", Array.length(items) == 3)
  TestKit.check(
    "each fixture item decodes a box that holds it inside the 64x48 photo",
    Array.every(items, item =>
      switch Json.field(item, "box")->Option.flatMap(Shared.decodeBox) {
      | Some(b) => b.x1 >= 0 && (b.y1 >= 0 && (b.x2 <= 64 && b.y2 <= 48))
      | None => false
      }
    ),
  )

  let logPath = Node.Path.join([dataDir, "scenes.jsonl"])
  TestKit.check("scenes.jsonl was written", Node.Fs.existsSync(logPath))
  let logText = Node.Fs.readFileUtf8(logPath, "utf8")
  TestKit.check("scenes.jsonl has a line", String.length(String.trim(logText)) > 0)

  let badResp = await Fetch.fetch(
    "http://127.0.0.1:" ++ Int.toString(port) ++ "/api/scene?model=gpt-4",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "image/jpeg")]),
      body: "fixture-mode-ignores-this-body",
    },
  )
  TestKit.check("POST /api/scene?model=gpt-4 responds 400", Fetch.status(badResp) == 400)
  let badJson = await Fetch.json(badResp)
  TestKit.check("400 reply has an error field", Json.stringField(badJson, "error")->Option.isSome)
  let validModels = Json.arrayField(badJson, "validModels")->Option.getOr([])
  TestKit.check("400 reply lists 3 valid model ids", Array.length(validModels) == 3)

  // -- Haul mode: POST /api/hauls/:id/place (docs/haul-map-build.md step 4) --
  TestKit.section("Server: POST /api/hauls/:id/place")

  let base = "http://127.0.0.1:" ++ Int.toString(port)

  let (placeCreateStatus, placeCreateJson) = {
    let resp = await Fetch.fetch(
      base ++ "/api/hauls",
      ~init={
        Fetch.method: "POST",
        headers: Dict.fromArray([("content-type", "application/json")]),
        body: JSON.stringify(Json.obj([("name", Json.str("Place test"))])),
      },
    )
    (Fetch.status(resp), await Fetch.json(resp))
  }
  TestKit.check("POST /api/hauls (for place tests) responds 201", placeCreateStatus == 201)
  let placeHaulId = Json.stringField(placeCreateJson, "haulId")->Option.getOr("")
  TestKit.check("place-test haul has a haulId", placeHaulId != "")

  let postPlaceBody = async (haulId: string, body: string) => {
    let resp = await Fetch.fetch(
      base ++ "/api/hauls/" ++ haulId ++ "/place",
      ~init={
        Fetch.method: "POST",
        headers: Dict.fromArray([("content-type", "application/json")]),
        body,
      },
    )
    (Fetch.status(resp), await Fetch.json(resp))
  }

  let gpsBody = JSON.stringify(
    Json.obj([
      ("lat", Json.num(47.6)),
      ("lon", Json.num(-122.3)),
      ("accuracyM", Json.num(12.0)),
      ("source", Json.str("gps")),
    ]),
  )
  let (gpsStatus, gpsJson) = await postPlaceBody(placeHaulId, gpsBody)
  TestKit.check("valid gps place responds 200", gpsStatus == 200)
  let gpsPlace = Json.field(gpsJson, "place")->Option.getOr(Json.obj([]))
  TestKit.check("reply's place has source gps", Json.stringField(gpsPlace, "source") == Some("gps"))
  TestKit.check("reply's haulId matches", Json.stringField(gpsJson, "haulId") == Some(placeHaulId))

  let badLatBody = JSON.stringify(
    Json.obj([
      ("lat", Json.num(91.0)),
      ("lon", Json.num(-122.3)),
      ("accuracyM", Json.num(12.0)),
      ("source", Json.str("gps")),
    ]),
  )
  let (badLatStatus, _) = await postPlaceBody(placeHaulId, badLatBody)
  TestKit.check("lat 91 responds 400", badLatStatus == 400)

  let (badJsonStatus, _) = await postPlaceBody(placeHaulId, "not json")
  TestKit.check("malformed JSON body responds 400", badJsonStatus == 400)

  let (unknownStatus, _) = await postPlaceBody("no-such-haul", gpsBody)
  TestKit.check("unknown haul id responds 404", unknownStatus == 404)

  let pinBody = JSON.stringify(
    Json.obj([("lat", Json.num(47.61)), ("lon", Json.num(-122.31)), ("source", Json.str("pin"))]),
  )
  let (pinStatus, pinJson) = await postPlaceBody(placeHaulId, pinBody)
  TestKit.check("pin place responds 200", pinStatus == 200)
  let pinPlace = Json.field(pinJson, "place")->Option.getOr(Json.obj([]))
  TestKit.check("pin place source is pin", Json.stringField(pinPlace, "source") == Some("pin"))

  let gpsAfterPinBody = JSON.stringify(
    Json.obj([
      ("lat", Json.num(47.62)),
      ("lon", Json.num(-122.32)),
      ("accuracyM", Json.num(9.0)),
      ("source", Json.str("gps")),
    ]),
  )
  let (gpsAfterPinStatus, gpsAfterPinJson) = await postPlaceBody(placeHaulId, gpsAfterPinBody)
  TestKit.check("gps after pin still responds 200", gpsAfterPinStatus == 200)
  let gpsAfterPinPlace = Json.field(gpsAfterPinJson, "place")->Option.getOr(Json.obj([]))
  TestKit.check(
    "gps after pin keeps the pin (source stays pin)",
    Json.stringField(gpsAfterPinPlace, "source") == Some("pin"),
  )

  Node.HttpServer.close(server, () => ())
}
