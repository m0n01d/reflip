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

  Node.HttpServer.close(server, () => ())
}
