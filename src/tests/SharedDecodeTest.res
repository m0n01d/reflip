// Shared.decodeSceneReply against a real /api/scene reply in fixture mode
// (same server-start pattern as ServerTest.res) — the actual bytes the
// page will decode, not a hand-built stand-in.

let run = async () => {
  TestKit.section("Shared.decodeSceneReply")

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

  let {Server.server, port} = await Server.start(config)
  // The size now comes off the real bytes (JpegSize.res), so this POSTs the
  // real fixture photo — see ServerTest.res's comment for the same change.
  let photo = Node.Fs.readFileBuffer(Node.Path.join([cwd, "tests/fixtures/table.jpg"]))
  let resp = await Fetch.fetchBuffer(
    "http://127.0.0.1:" ++ Int.toString(port) ++ "/api/scene",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "image/jpeg")]),
      body: photo,
    },
  )
  let json = await Fetch.json(resp)

  switch Shared.decodeSceneReply(json) {
  | Error(msg) => TestKit.check("the fixture reply decodes (" ++ msg ++ ")", false)
  | Ok(reply) => {
      TestKit.check("decoded reply is marked fixture=true", reply.fixture)
      TestKit.check("decoded reply has 3 items", Array.length(reply.items) == 3)
      TestKit.check("decoded reply has a sceneId", String.length(reply.sceneId) > 0)
      TestKit.check("decoded reply's cost is non-negative", reply.cost.usd >= 0.0)
      TestKit.check(
        "decoded items each have a sold-search URL",
        Array.every(reply.items, item => String.length(item.soldSearchUrl) > 0),
      )
      TestKit.check("decoded reply carries quarterSeen from the fixture (true)", reply.quarterSeen)
      TestKit.check(
        "decoded items carry a size, including the empty-string and missing cases",
        Array.map(reply.items, item => item.size) == ["", "10 in", ""],
      )
      TestKit.check(
        "decoded reply's imageWidth/imageHeight match the real fixture photo (64x48)",
        reply.imageWidth == 64 && reply.imageHeight == 48,
      )
      TestKit.check(
        "decoded items each have a box (the fixture gives all 3 one)",
        Array.every(reply.items, item => item.box->Option.isSome),
      )
    }
  }

  TestKit.section("Shared.decodeHaulGem")

  let gemWithBoxJson = Json.obj([
    ("findId", Json.str("find-1")),
    ("sceneId", Json.str("scene-1")),
    ("name", Json.str("Brass table lamp")),
    ("estimateLowUsd", Json.num(20.0)),
    ("estimateHighUsd", Json.num(45.0)),
    ("confidence", Json.num(0.8)),
    ("soldSearchUrl", Json.str("https://www.ebay.com/sch/i.html?_nkw=lamp")),
    ("box", Json.arr([Json.num(2.0), Json.num(4.0), Json.num(20.0), Json.num(30.0)])),
    ("imageWidth", Json.num(64.0)),
    ("imageHeight", Json.num(48.0)),
  ])
  switch Shared.decodeHaulGem(gemWithBoxJson) {
  | Error(msg) => TestKit.check("a gem with a box and a size decodes (" ++ msg ++ ")", false)
  | Ok(gem) => {
      TestKit.check(
        "decodeHaulGem decodes the box",
        gem.box == Some({Types.x1: 2, y1: 4, x2: 20, y2: 30}),
      )
      TestKit.check(
        "decodeHaulGem decodes the size",
        gem.imageWidth == Some(64) && gem.imageHeight == Some(48),
      )
    }
  }

  // A gem with no box/imageWidth/imageHeight fields at all — the shape a
  // pre-2026-09-25 status reply would have had. Every missing field must
  // decode to None, not an error.
  let gemNoBoxJson = Json.obj([
    ("findId", Json.str("find-2")),
    ("sceneId", Json.str("scene-2")),
    ("name", Json.str("Griswold cast iron skillet")),
    ("estimateLowUsd", Json.num(20.0)),
    ("estimateHighUsd", Json.num(60.0)),
    ("confidence", Json.num(0.7)),
    ("soldSearchUrl", Json.str("https://www.ebay.com/sch/i.html?_nkw=skillet")),
  ])
  switch Shared.decodeHaulGem(gemNoBoxJson) {
  | Error(msg) => TestKit.check("a gem missing box/size fields decodes (" ++ msg ++ ")", false)
  | Ok(gem) =>
    TestKit.check(
      "decodeHaulGem leaves box and size None when the fields are absent",
      gem.box == None && gem.imageWidth == None && gem.imageHeight == None,
    )
  }

  Node.HttpServer.close(server, () => ())
}
