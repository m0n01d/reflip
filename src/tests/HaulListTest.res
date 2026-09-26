// HaulList.build and HaulList.fromStore, and the GET /api/hauls route
// parse. Per docs/haul-map-build.md's design notes for step 3.

let cwd = Node.Process.cwd()

let baseHaul: Store.haul = {
  haulId: "haul-1",
  name: None,
  startedAt: "2026-09-24T10:00:00.000Z",
  doneAt: None,
  emailedAt: None,
  costUsd: 0.0,
  stopReason: None,
  emailNote: None,
  place: None,
}

let baseFind: Store.find = {
  findId: "find-1",
  sceneId: "scene-1",
  model: "claude-sonnet-5",
  fixture: true,
  name: "A gem",
  query: "a gem query",
  where: None,
  estimateLowUsd: 10.0,
  estimateHighUsd: 20.0,
  confidence: 0.5,
  category: None,
  promptVersion: "v1",
  ebayJson: None,
  paidUsd: None,
  soldUsd: None,
  soldOn: None,
  soldWhere: None,
  createdAt: "2026-09-24T10:01:00.000Z",
  size: "1x",
  box: None,
}

let basePlace: Types.place = {
  lat: 47.0,
  lon: -122.0,
  accuracyM: Some(5.0),
  source: Gps,
  at: "2026-09-24T09:59:00.000Z",
}

let run = () => {
  TestKit.section("HaulList.build")

  // -- order: build trusts the caller's order, it does no sorting of its own --
  let haulNew = {...baseHaul, haulId: "haul-new", startedAt: "2026-09-25T00:00:00.000Z"}
  let haulOld = {...baseHaul, haulId: "haul-old", startedAt: "2026-09-24T00:00:00.000Z"}
  let orderedRows = HaulList.build(
    ~hauls=[haulNew, haulOld],
    ~photoCounts=Dict.make(),
    ~finds=[],
    ~gemMinUsd=20.0,
  )
  TestKit.check(
    "already-newest-first input keeps that order",
    orderedRows->Array.map(r => r.Types.haulId) == ["haul-new", "haul-old"],
  )

  // -- place: None and Some pass through untouched --
  let haulNoPlace = {...baseHaul, haulId: "haul-no-place", place: None}
  let haulWithPlace = {...baseHaul, haulId: "haul-with-place", place: Some(basePlace)}
  let placeRows = HaulList.build(
    ~hauls=[haulNoPlace, haulWithPlace],
    ~photoCounts=Dict.make(),
    ~finds=[],
    ~gemMinUsd=20.0,
  )
  TestKit.check(
    "a haul with no place gets place: None",
    switch placeRows->Array.getUnsafe(0) {
    | {haulId: "haul-no-place", place: None} => true
    | _ => false
    },
  )
  TestKit.check(
    "a haul with a place gets that place back",
    switch placeRows->Array.getUnsafe(1) {
    | {haulId: "haul-with-place", place: Some(p)} => p == basePlace
    | _ => false
    },
  )

  // -- photoCount: absent from the dict is 0, present is that count --
  let photoCounts = Dict.make()
  Dict.set(photoCounts, "haul-2", 3)
  let countRows = HaulList.build(
    ~hauls=[{...baseHaul, haulId: "haul-1"}, {...baseHaul, haulId: "haul-2"}],
    ~photoCounts,
    ~finds=[],
    ~gemMinUsd=20.0,
  )
  TestKit.check(
    "a haul absent from photoCounts gets photoCount 0",
    (countRows->Array.getUnsafe(0)).photoCount == 0,
  )
  TestKit.check(
    "a haul present in photoCounts gets its count",
    (countRows->Array.getUnsafe(1)).photoCount == 3,
  )

  // -- gemCount: >= gemMinUsd counts, just under does not --
  let atThreshold = {...baseFind, findId: "find-at", estimateHighUsd: 20.0}
  let underThreshold = {...baseFind, findId: "find-under", estimateHighUsd: 19.99}
  let gemRows = HaulList.build(
    ~hauls=[baseHaul],
    ~photoCounts=Dict.make(),
    ~finds=[("haul-1", atThreshold), ("haul-1", underThreshold)],
    ~gemMinUsd=20.0,
  )
  TestKit.check(
    "estimateHighUsd exactly at gemMinUsd counts as a gem",
    (gemRows->Array.getUnsafe(0)).gemCount == 1,
  )

  // -- buys: only paid finds become a buy; paidOn is always None; paidUsd sums --
  let paidFind = {...baseFind, findId: "find-paid", paidUsd: Some(12.5)}
  let unpaidFind = {...baseFind, findId: "find-unpaid", paidUsd: None}
  let buyRows = HaulList.build(
    ~hauls=[baseHaul],
    ~photoCounts=Dict.make(),
    ~finds=[("haul-1", paidFind), ("haul-1", unpaidFind)],
    ~gemMinUsd=20.0,
  )
  let buyRow = buyRows->Array.getUnsafe(0)
  TestKit.check("an unpaid find does not become a buy", Array.length(buyRow.buys) == 1)
  TestKit.check("a buy's paidOn is always None", (buyRow.buys->Array.getUnsafe(0)).paidOn == None)
  TestKit.check("the row's paidUsd is the one buy's amount", buyRow.paidUsd == 12.5)

  let paidFind2 = {...baseFind, findId: "find-paid-2", paidUsd: Some(7.5)}
  let twoPaidRows = HaulList.build(
    ~hauls=[baseHaul],
    ~photoCounts=Dict.make(),
    ~finds=[("haul-1", paidFind), ("haul-1", paidFind2)],
    ~gemMinUsd=20.0,
  )
  TestKit.check(
    "two paid finds sum both amounts",
    (twoPaidRows->Array.getUnsafe(0)).paidUsd == 20.0,
  )

  // -- encode: the row's and one buy's key sets, exactly --
  let encodedRow = Types.encodeHaulList([buyRow])
  switch JSON.Decode.array(encodedRow)->Option.flatMap(rows => rows[0]) {
  | Some(rowJson) =>
    switch JSON.Decode.object(rowJson) {
    | Some(rowDict) =>
      let keys = Dict.keysToArray(rowDict)
      let expected = [
        "haulId",
        "name",
        "startedAt",
        "place",
        "photoCount",
        "gemCount",
        "paidUsd",
        "buys",
      ]
      TestKit.check(
        "a row has exactly the expected keys",
        Array.length(keys) == Array.length(expected),
      )
      TestKit.check(
        "every expected row key is present",
        Array.every(expected, k => Array.includes(keys, k)),
      )
      TestKit.check(
        "no extra row key is present",
        Array.every(keys, k => Array.includes(expected, k)),
      )
      switch Json.field(rowJson, "buys")
      ->Option.flatMap(JSON.Decode.array)
      ->Option.flatMap(bs => bs[0]) {
      | Some(buyJson) =>
        switch JSON.Decode.object(buyJson) {
        | Some(buyDict) =>
          let buyKeys = Dict.keysToArray(buyDict)
          let expectedBuyKeys = ["name", "paidUsd", "paidOn", "soldUsd", "soldOn"]
          TestKit.check(
            "a buy has exactly the expected keys",
            Array.length(buyKeys) == Array.length(expectedBuyKeys),
          )
          TestKit.check(
            "every expected buy key is present",
            Array.every(expectedBuyKeys, k => Array.includes(buyKeys, k)),
          )
        | None => TestKit.check("a buy decodes as a JSON object", false)
        }
      | None => TestKit.check("the row has at least one buy to check", false)
      }
    | None => TestKit.check("a row decodes as a JSON object", false)
    }
  | None => TestKit.check("encodeHaulList produced a non-empty array", false)
  }

  // -- round trip: encode then decode gets the same row back --
  switch Shared.decodeHaulList(Types.encodeHaulList([buyRow])) {
  | Ok([decoded]) => TestKit.check("decodeHaulList round-trips the row", decoded == buyRow)
  | _ => TestKit.check("decodeHaulList round-trips the row", false)
  }

  TestKit.section("HaulList.fromStore")

  // Three hauls: two share the same (later) startedAt, to exercise the
  // rowid DESC tiebreak -- the later-inserted one must come first.
  let db = Store.openAt(":memory:")
  let config: Config.t = {
    port: 0,
    fixtures: true,
    dataDir: Node.Path.join([Node.Os.tmpdir(), "reflip-hauls-test"]),
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

  Store.createHaul(db, ~haulId="haul-old", ~name=None, ~now="2026-09-20T00:00:00.000Z")->ignore
  Store.createHaul(db, ~haulId="haul-tie-1", ~name=None, ~now="2026-09-25T00:00:00.000Z")->ignore
  Store.createHaul(db, ~haulId="haul-tie-2", ~name=None, ~now="2026-09-25T00:00:00.000Z")->ignore

  Store.addScene(
    db,
    ~haulId="haul-old",
    ~clientId="client-1",
    ~sceneId="scene-old-1",
    ~photoPath="data/photos/scene-old-1.jpg",
    ~now="2026-09-20T00:01:00.000Z",
    ~imageWidth=None,
    ~imageHeight=None,
  )->ignore
  Store.addScene(
    db,
    ~haulId="haul-old",
    ~clientId="client-2",
    ~sceneId="scene-old-2",
    ~photoPath="data/photos/scene-old-2.jpg",
    ~now="2026-09-20T00:02:00.000Z",
    ~imageWidth=None,
    ~imageHeight=None,
  )->ignore
  Store.insertFind(
    db,
    {
      Store.findId: "find-old-1",
      sceneId: "scene-old-1",
      model: "claude-sonnet-5",
      fixture: true,
      name: "Old gem",
      query: "old gem query",
      where: None,
      estimateLowUsd: 5.0,
      estimateHighUsd: 15.0,
      confidence: 0.5,
      category: None,
      promptVersion: "v1",
      ebayJson: None,
      paidUsd: Some(3.0),
      soldUsd: None,
      soldOn: None,
      soldWhere: None,
      createdAt: "2026-09-20T00:03:00.000Z",
      size: "1x",
      box: None,
    },
  )

  let rows = HaulList.fromStore(db, config)
  TestKit.check(
    "newest-first with the rowid tiebreak: later insert wins the tie",
    rows->Array.map(r => r.Types.haulId) == ["haul-tie-2", "haul-tie-1", "haul-old"],
  )
  switch rows->Array.getUnsafe(2) {
  | {haulId: "haul-old", photoCount: 2, paidUsd: 3.0} =>
    TestKit.check("haul-old's photoCount and paidUsd come from the real store", true)
  | _ => TestKit.check("haul-old's photoCount and paidUsd come from the real store", false)
  }
  Store.close(db)

  TestKit.section("Server.parseHaulPath")

  TestKit.check(
    "GET /api/hauls parses as ListHauls",
    Server.parseHaulPath("GET", "/api/hauls") == Some(Server.ListHauls),
  )
  TestKit.check(
    "POST /api/hauls still parses as CreateHaul",
    Server.parseHaulPath("POST", "/api/hauls") == Some(Server.CreateHaul),
  )
}
