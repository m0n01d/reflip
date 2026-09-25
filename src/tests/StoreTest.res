// Unit tests for Store.res, against an in-memory SQLite database.

let run = () => {
  let db = Store.openAt(":memory:")

  // -- createHaul / getHaul --------------------------------------------------
  TestKit.section("Store: createHaul / getHaul")

  let h1 = Store.createHaul(db, ~haulId="haul-1", ~name=Some("Goodwill on 5th"), ~now="2026-09-24T10:00:00.000Z")
  TestKit.check("createHaul returns the haulId", h1.haulId == "haul-1")
  TestKit.check("createHaul returns the name", h1.name == Some("Goodwill on 5th"))
  TestKit.check("createHaul starts at costUsd 0", h1.costUsd == 0.0)
  TestKit.check("createHaul has no stopReason yet", h1.stopReason == None)

  switch Store.getHaul(db, "haul-1") {
  | Some(h) => {
      TestKit.check("getHaul finds the row", h.haulId == "haul-1")
      TestKit.check("getHaul round-trips the name", h.name == Some("Goodwill on 5th"))
      TestKit.check("getHaul round-trips startedAt", h.startedAt == "2026-09-24T10:00:00.000Z")
    }
  | None => TestKit.check("getHaul found haul-1", false)
  }
  TestKit.check("getHaul on a missing id is None", Store.getHaul(db, "no-such-haul") == None)

  let _h2 = Store.createHaul(db, ~haulId="haul-2", ~name=None, ~now="2026-09-24T10:05:00.000Z")

  // -- addScene: same clientId twice gives one row ---------------------------
  TestKit.section("Store: addScene dedupes by clientId")

  let s1 = Store.addScene(
    db,
    ~haulId="haul-1",
    ~clientId="client-1",
    ~sceneId="scene-1",
    ~photoPath="data/photos/scene-1.jpg",
    ~now="2026-09-24T10:01:00.000Z",
    ~imageWidth=None,
    ~imageHeight=None,
  )
  TestKit.check("addScene inserts as queued", s1.status == Store.Queued)

  let s1retry = Store.addScene(
    db,
    ~haulId="haul-1",
    ~clientId="client-1",
    ~sceneId="scene-1-retry",
    ~photoPath="data/photos/scene-1-retry.jpg",
    ~now="2026-09-24T10:01:05.000Z",
    ~imageWidth=None,
    ~imageHeight=None,
  )
  TestKit.check("a retried upload returns the same sceneId", s1retry.sceneId == "scene-1")
  TestKit.check(
    "a retried upload keeps the original photoPath",
    s1retry.photoPath == "data/photos/scene-1.jpg",
  )
  TestKit.check(
    "only one row exists for the clientId",
    Array.length(Store.scenesOf(db, "haul-1")) == 1,
  )

  // -- addScene: the photo size round-trips ------------------------------------
  TestKit.section("Store: addScene stores and round-trips the photo size")

  let sSized = Store.addScene(
    db,
    ~haulId="haul-1",
    ~clientId="client-sized",
    ~sceneId="scene-sized",
    ~photoPath="data/photos/scene-sized.jpg",
    ~now="2026-09-24T10:02:00.000Z",
    ~imageWidth=Some(800),
    ~imageHeight=Some(600),
  )
  TestKit.check(
    "addScene returns the size it was given",
    sSized.imageWidth == Some(800) && sSized.imageHeight == Some(600),
  )
  switch Store.sceneByClient(db, ~haulId="haul-1", ~clientId="client-sized") {
  | Some(s) =>
    TestKit.check(
      "the size round-trips through a fresh read",
      s.imageWidth == Some(800) && s.imageHeight == Some(600),
    )
  | None => TestKit.check("sceneByClient found the sized scene", false)
  }

  let sNoSize = Store.addScene(
    db,
    ~haulId="haul-1",
    ~clientId="client-nosize",
    ~sceneId="scene-nosize",
    ~photoPath="data/photos/scene-nosize.jpg",
    ~now="2026-09-24T10:03:00.000Z",
    ~imageWidth=None,
    ~imageHeight=None,
  )
  TestKit.check(
    "addScene with no size leaves both fields None",
    sNoSize.imageWidth == None && sNoSize.imageHeight == None,
  )
  switch Store.sceneByClient(db, ~haulId="haul-1", ~clientId="client-nosize") {
  | Some(s) =>
    TestKit.check(
      "a fresh read of the no-size scene keeps both fields None",
      s.imageWidth == None && s.imageHeight == None,
    )
  | None => TestKit.check("sceneByClient found the no-size scene", false)
  }

  // -- nextQueued: FIFO and skips a stopped haul -----------------------------
  TestKit.section("Store: nextQueued is FIFO and skips a stopped haul")

  let _f1 = Store.addScene(
    db,
    ~haulId="haul-2",
    ~clientId="f-1",
    ~sceneId="f1",
    ~photoPath="data/photos/f1.jpg",
    ~now="2026-09-24T09:00:01.000Z",
    ~imageWidth=None,
    ~imageHeight=None,
  )
  let _f2 = Store.addScene(
    db,
    ~haulId="haul-2",
    ~clientId="f-2",
    ~sceneId="f2",
    ~photoPath="data/photos/f2.jpg",
    ~now="2026-09-24T09:00:02.000Z",
    ~imageWidth=None,
    ~imageHeight=None,
  )
  let _f3 = Store.addScene(
    db,
    ~haulId="haul-2",
    ~clientId="f-3",
    ~sceneId="f3",
    ~photoPath="data/photos/f3.jpg",
    ~now="2026-09-24T09:00:03.000Z",
    ~imageWidth=None,
    ~imageHeight=None,
  )

  switch Store.nextQueued(db) {
  | Some(s) => TestKit.check("nextQueued picks the oldest queued scene first", s.sceneId == "f1")
  | None => TestKit.check("nextQueued found a scene", false)
  }
  Store.setStatus(db, ~sceneId="f1", Store.Running)
  switch Store.nextQueued(db) {
  | Some(s) => TestKit.check("nextQueued moves on once f1 is running", s.sceneId == "f2")
  | None => TestKit.check("nextQueued found a scene after f1 left queued", false)
  }
  Store.setStatus(db, ~sceneId="f2", Store.Running)

  // A haul with an earlier scene than haul-2's remaining queue, but stopped.
  let _stoppedHaul = Store.createHaul(
    db,
    ~haulId="haul-stopped",
    ~name=None,
    ~now="2026-09-24T08:00:00.000Z",
  )
  let _st1 = Store.addScene(
    db,
    ~haulId="haul-stopped",
    ~clientId="st-1",
    ~sceneId="st1",
    ~photoPath="data/photos/st1.jpg",
    ~now="2026-09-24T08:00:01.000Z",
    ~imageWidth=None,
    ~imageHeight=None,
  )
  Store.stopHaul(db, ~haulId="haul-stopped", ~reason="budget")
  switch Store.nextQueued(db) {
  | Some(s) =>
    TestKit.check("nextQueued skips the stopped haul's earlier scene", s.sceneId == "f3")
  | None => TestKit.check("nextQueued found f3, skipping the stopped haul", false)
  }

  // -- resetRunning -----------------------------------------------------------
  TestKit.section("Store: resetRunning")

  let resetCount = Store.resetRunning(db)
  TestKit.check("resetRunning resets f1 and f2", resetCount == 2)
  switch Store.sceneByClient(db, ~haulId="haul-2", ~clientId="f-1") {
  | Some(s) => TestKit.check("f1 is queued again", s.status == Store.Queued)
  | None => TestKit.check("f1 still exists after reset", false)
  }
  switch Store.sceneByClient(db, ~haulId="haul-2", ~clientId="f-2") {
  | Some(s) => TestKit.check("f2 is queued again", s.status == Store.Queued)
  | None => TestKit.check("f2 still exists after reset", false)
  }

  // -- finishScene / failScene -------------------------------------------------
  TestKit.section("Store: finishScene / failScene")

  Store.finishScene(db, ~sceneId="f3", ~costUsd=0.152, ~claudeMs=47123.0, ~otherCount=Some(5))
  switch Store.sceneByClient(db, ~haulId="haul-2", ~clientId="f-3") {
  | Some(s) => {
      TestKit.check("finishScene sets status done", s.status == Store.Done)
      TestKit.approx("finishScene sets costUsd", s.costUsd->Option.getOr(-1.0), 0.152, ~eps=1e-9)
      TestKit.approx(
        "finishScene sets claudeMs",
        s.claudeMs->Option.getOr(-1.0),
        47123.0,
        ~eps=1e-9,
      )
      TestKit.check("finishScene sets otherCount", s.otherCount == Some(5))
    }
  | None => TestKit.check("f3 exists after finishScene", false)
  }

  Store.failScene(db, ~sceneId="f2", ~error="reply cut off", ~costUsd=Some(0.02), ~claudeMs=Some(500.0))
  switch Store.sceneByClient(db, ~haulId="haul-2", ~clientId="f-2") {
  | Some(s) => {
      TestKit.check("failScene sets status failed", s.status == Store.Failed)
      TestKit.check("failScene sets the error", s.error == Some("reply cut off"))
      TestKit.approx("failScene sets costUsd", s.costUsd->Option.getOr(-1.0), 0.02, ~eps=1e-9)
    }
  | None => TestKit.check("f2 exists after failScene", false)
  }

  // failScene with no cost/time yet (a failure before the Claude call returned).
  let _haulFailNone = Store.createHaul(
    db,
    ~haulId="haul-fail-none",
    ~name=None,
    ~now="2026-09-24T09:30:00.000Z",
  )
  let _n1 = Store.addScene(
    db,
    ~haulId="haul-fail-none",
    ~clientId="n-1",
    ~sceneId="n1",
    ~photoPath="data/photos/n1.jpg",
    ~now="2026-09-24T09:30:01.000Z",
    ~imageWidth=None,
    ~imageHeight=None,
  )
  Store.failScene(db, ~sceneId="n1", ~error="network", ~costUsd=None, ~claudeMs=None)
  switch Store.sceneByClient(db, ~haulId="haul-fail-none", ~clientId="n-1") {
  | Some(s) => {
      TestKit.check("failScene with no cost leaves costUsd None", s.costUsd == None)
      TestKit.check("failScene with no time leaves claudeMs None", s.claudeMs == None)
      TestKit.check("failScene still records the error", s.error == Some("network"))
    }
  | None => TestKit.check("n1 exists after failScene", false)
  }

  // -- insertFind / findsOf round trip -----------------------------------------
  TestKit.section("Store: insertFind / findsOf round trip")

  let trickyWhere = "shelf 2, next to the \"lamp\", it's a gem — é"
  let find: Store.find = {
    findId: "find-1",
    sceneId: "f3",
    model: "claude-sonnet-5",
    fixture: true,
    name: "Brass candlestick",
    query: "vintage brass candlestick",
    where: Some(trickyWhere),
    estimateLowUsd: 20.0,
    estimateHighUsd: 45.0,
    confidence: 0.8,
    category: Some("home"),
    promptVersion: "haul-v1",
    ebayJson: None,
    paidUsd: None,
    soldUsd: None,
    soldOn: None,
    soldWhere: None,
    createdAt: "2026-09-24T09:10:00.000Z",
    size: "10 in skillet",
    box: Some({Types.x1: 2, y1: 4, x2: 20, y2: 30}),
  }
  Store.insertFind(db, find)

  let finds = Store.findsOf(db, "haul-2")
  TestKit.check("findsOf returns the inserted find", Array.length(finds) == 1)
  switch Array.get(finds, 0) {
  | Some(f) => {
      TestKit.check("findsOf round-trips findId", f.findId == "find-1")
      TestKit.check("findsOf round-trips fixture as a bool", f.fixture == true)
      TestKit.check(
        "findsOf round-trips a quote, an apostrophe and an accented letter in \"where\"",
        f.where == Some(trickyWhere),
      )
      TestKit.approx("findsOf round-trips estimateLowUsd", f.estimateLowUsd, 20.0, ~eps=1e-9)
      TestKit.check(
        "findsOf round-trips a box",
        f.box == Some({Types.x1: 2, y1: 4, x2: 20, y2: 30}),
      )
      TestKit.check("findsOf round-trips size", f.size == "10 in skillet")
    }
  | None => TestKit.check("findsOf returned a row", false)
  }

  // -- migrating a pre-box, pre-size finds table on open ------------------------
  TestKit.section("Store: migrates a finds table with no box or size columns")

  let migPath = Node.Path.join([
    Node.Os.tmpdir(),
    "reflip-store-test-" ++ Node.Crypto.randomUUID() ++ ".db",
  ])

  // The pre-box, pre-size `finds` schema, hand-built with the raw Sqlite
  // binding — the same shape Store.openAt's own CREATE TABLE IF NOT EXISTS
  // wrote before this change, and so a no-op against a DB that already has
  // both columns.
  let oldDb = Sqlite.make(migPath)
  Sqlite.exec(
    oldDb,
    `CREATE TABLE finds (
      findId TEXT PRIMARY KEY,
      sceneId TEXT NOT NULL,
      model TEXT NOT NULL,
      fixture INTEGER NOT NULL,
      name TEXT NOT NULL,
      query TEXT NOT NULL,
      "where" TEXT,
      estimateLowUsd REAL NOT NULL,
      estimateHighUsd REAL NOT NULL,
      confidence REAL NOT NULL,
      category TEXT,
      promptVersion TEXT NOT NULL,
      ebayJson TEXT,
      paidUsd REAL,
      soldUsd REAL,
      soldOn TEXT,
      soldWhere TEXT,
      createdAt TEXT NOT NULL
    )`,
  )
  Sqlite.close(oldDb)

  let migDb = Store.openAt(migPath)
  Store.createHaul(migDb, ~haulId="haul-mig", ~name=None, ~now="2026-09-24T12:00:00.000Z")->ignore
  Store.addScene(
    migDb,
    ~haulId="haul-mig",
    ~clientId="client-mig",
    ~sceneId="scene-mig",
    ~photoPath="data/photos/scene-mig.jpg",
    ~now="2026-09-24T12:00:01.000Z",
    ~imageWidth=None,
    ~imageHeight=None,
  )->ignore
  Store.insertFind(
    migDb,
    {
      Store.findId: "find-mig",
      sceneId: "scene-mig",
      model: "claude-sonnet-5",
      fixture: true,
      name: "Migrated gem",
      query: "migrated gem query",
      where: Some("shelf"),
      estimateLowUsd: 10.0,
      estimateHighUsd: 20.0,
      confidence: 0.5,
      category: None,
      promptVersion: "haul-2",
      ebayJson: None,
      paidUsd: None,
      soldUsd: None,
      soldOn: None,
      soldWhere: None,
      createdAt: "2026-09-24T12:00:02.000Z",
      size: "10 in",
      box: Some({Types.x1: 2, y1: 4, x2: 20, y2: 30}),
    },
  )

  let migFinds = Store.findsOf(migDb, "haul-mig")
  TestKit.check("a DB with the old finds schema opens and stores a find", Array.length(migFinds) == 1)
  switch Array.get(migFinds, 0) {
  | Some(f) => {
      TestKit.check(
        "the migrated columns round-trip a box",
        f.box == Some({Types.x1: 2, y1: 4, x2: 20, y2: 30}),
      )
      TestKit.check("the migrated columns round-trip size", f.size == "10 in")
    }
  | None => TestKit.check("findsOf returned the migrated find", false)
  }
  Store.close(migDb)

  // Opening the same file again must not fail now that both columns exist.
  let reopened = Store.openAt(migPath)
  let selectFind = db =>
    Sqlite.get(Sqlite.prepare(db, "SELECT * FROM finds WHERE findId = ?"), [Sqlite.Text("find-mig")])
    ->Option.flatMap(Store.decodeFind)
  switch selectFind(reopened) {
  | Some(f) =>
    TestKit.check(
      "a second open keeps the find, its box and its size",
      f.box == Some({Types.x1: 2, y1: 4, x2: 20, y2: 30}) && f.size == "10 in",
    )
  | None => TestKit.check("the find survives a second open", false)
  }
  Store.close(reopened)

  // -- migrating a pre-size scenes table on open --------------------------------
  TestKit.section("Store: migrates a scenes table with no size columns")

  let migDir2 = Node.Path.join([Node.Os.tmpdir(), "reflip-store-test-" ++ Node.Crypto.randomUUID()])
  Node.Fs.mkdirSync(migDir2, {recursive: true})
  let migPath2 = Node.Path.join([migDir2, "old.db"])

  // The pre-size `scenes` schema, hand-built with the raw Sqlite binding —
  // the same shape Store.openAt's own CREATE TABLE IF NOT EXISTS wrote
  // before this change, and so a no-op against a DB that already has it.
  let oldDb2 = Sqlite.make(migPath2)
  Sqlite.exec(
    oldDb2,
    `CREATE TABLE scenes (
      sceneId TEXT PRIMARY KEY,
      haulId TEXT NOT NULL,
      clientId TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('queued','running','done','failed')),
      photoPath TEXT NOT NULL,
      error TEXT,
      costUsd REAL,
      claudeMs REAL,
      otherCount INTEGER,
      createdAt TEXT NOT NULL,
      UNIQUE (haulId, clientId)
    )`,
  )
  // A scene row written under the old schema, before the size columns
  // existed — the shape a pre-2026-09-25 scene has on disk today.
  Sqlite.exec(
    oldDb2,
    `INSERT INTO scenes (sceneId, haulId, clientId, status, photoPath, createdAt)
     VALUES ('scene-presize', 'haul-mig2', 'client-presize', 'queued', 'data/photos/scene-presize.jpg', '2026-09-25T11:59:00.000Z')`,
  )
  Sqlite.close(oldDb2)

  let migDb2 = Store.openAt(migPath2)
  switch Store.sceneByClient(migDb2, ~haulId="haul-mig2", ~clientId="client-presize") {
  | Some(s) =>
    TestKit.check(
      "a pre-migration scene with no size columns reads back with None sizes",
      s.imageWidth == None && s.imageHeight == None,
    )
  | None => TestKit.check("sceneByClient found the pre-migration scene", false)
  }
  Store.createHaul(migDb2, ~haulId="haul-mig2", ~name=None, ~now="2026-09-25T12:00:00.000Z")->ignore
  let migScene = Store.addScene(
    migDb2,
    ~haulId="haul-mig2",
    ~clientId="client-mig2",
    ~sceneId="scene-mig2",
    ~photoPath="data/photos/scene-mig2.jpg",
    ~now="2026-09-25T12:00:01.000Z",
    ~imageWidth=Some(64),
    ~imageHeight=Some(48),
  )
  TestKit.check(
    "a DB with the old scenes schema opens and stores a scene's size",
    migScene.imageWidth == Some(64) && migScene.imageHeight == Some(48),
  )
  switch Store.sceneByClient(migDb2, ~haulId="haul-mig2", ~clientId="client-mig2") {
  | Some(s) =>
    TestKit.check(
      "the migrated size columns round-trip through a fresh read",
      s.imageWidth == Some(64) && s.imageHeight == Some(48),
    )
  | None => TestKit.check("sceneByClient found the migrated scene", false)
  }
  Store.close(migDb2)

  // -- counts -------------------------------------------------------------------
  TestKit.section("Store: counts")

  let c = Store.counts(db, "haul-2")
  TestKit.check("counts: queued", c.queued == 1)
  TestKit.check("counts: running", c.running == 0)
  TestKit.check("counts: done", c.done == 1)
  TestKit.check("counts: failed", c.failed == 1)

  // -- addHaulCost adds up --------------------------------------------------------
  TestKit.section("Store: addHaulCost adds up")

  let _haulCost = Store.createHaul(db, ~haulId="haul-cost", ~name=None, ~now="2026-09-24T10:10:00.000Z")
  let total1 = Store.addHaulCost(db, ~haulId="haul-cost", 0.10)
  TestKit.approx("addHaulCost after first add", total1, 0.10, ~eps=1e-9)
  let total2 = Store.addHaulCost(db, ~haulId="haul-cost", 0.05)
  TestKit.approx("addHaulCost accumulates", total2, 0.15, ~eps=1e-9)
  switch Store.getHaul(db, "haul-cost") {
  | Some(h) => TestKit.approx("addHaulCost persists on the row", h.costUsd, 0.15, ~eps=1e-9)
  | None => TestKit.check("haul-cost exists", false)
  }

  // -- stopHaul keeps the first reason ---------------------------------------------
  TestKit.section("Store: stopHaul keeps the first reason")

  let _haulStop = Store.createHaul(db, ~haulId="haul-stop", ~name=None, ~now="2026-09-24T10:20:00.000Z")
  Store.stopHaul(db, ~haulId="haul-stop", ~reason="budget")
  Store.stopHaul(db, ~haulId="haul-stop", ~reason="3 failures in a row")
  switch Store.getHaul(db, "haul-stop") {
  | Some(h) => TestKit.check("stopHaul keeps the first reason", h.stopReason == Some("budget"))
  | None => TestKit.check("haul-stop exists", false)
  }

  // -- markDone / markEmailed ------------------------------------------------------
  TestKit.section("Store: markDone / markEmailed")

  let _haulMark = Store.createHaul(db, ~haulId="haul-mark", ~name=None, ~now="2026-09-24T11:00:00.000Z")
  Store.markDone(db, ~haulId="haul-mark", ~now="2026-09-24T11:30:00.000Z")
  Store.markEmailed(db, ~haulId="haul-mark", ~now="2026-09-24T11:31:00.000Z", ~note=Some("3 gems"))
  switch Store.getHaul(db, "haul-mark") {
  | Some(h) => {
      TestKit.check("markDone sets doneAt", h.doneAt == Some("2026-09-24T11:30:00.000Z"))
      TestKit.check("markEmailed sets emailedAt", h.emailedAt == Some("2026-09-24T11:31:00.000Z"))
      TestKit.check("markEmailed sets emailNote", h.emailNote == Some("3 gems"))
    }
  | None => TestKit.check("haul-mark exists", false)
  }

  // -- row decoders return None for a missing column ---------------------------
  TestKit.section("Store: row decoders return None on a missing column")

  let noHaulId = Json.obj([("name", Json.str("x")), ("startedAt", Json.str("t")), ("costUsd", Json.num(0.0))])
  TestKit.check("decodeHaul with no haulId is None", Store.decodeHaul(noHaulId) == None)

  let noStatus = Json.obj([
    ("sceneId", Json.str("s")),
    ("haulId", Json.str("h")),
    ("clientId", Json.str("c")),
    ("photoPath", Json.str("p")),
    ("createdAt", Json.str("t")),
  ])
  TestKit.check("decodeScene with no status is None", Store.decodeScene(noStatus) == None)

  let noFindId = Json.obj([
    ("sceneId", Json.str("s")),
    ("model", Json.str("m")),
    ("fixture", Json.num(1.0)),
    ("name", Json.str("n")),
    ("query", Json.str("q")),
    ("estimateLowUsd", Json.num(1.0)),
    ("estimateHighUsd", Json.num(2.0)),
    ("confidence", Json.num(0.5)),
    ("promptVersion", Json.str("v1")),
    ("createdAt", Json.str("t")),
  ])
  TestKit.check("decodeFind with no findId is None", Store.decodeFind(noFindId) == None)

  Store.close(db)
}
