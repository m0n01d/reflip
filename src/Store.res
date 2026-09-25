// SQLite store for haul mode: hauls, scenes and finds. Per docs/spec-haul-mode.md
// "The brain" and CLAUDE.md — rows come back from Sqlite.res as JSON.t, and
// every decode returns option, never a cast. Timestamps are ISO text from
// Date.toISOString. Bools are INTEGER 0/1, so a bool column decodes through
// a number, not JSON.Decode.bool.

type t = Sqlite.t

type haul = {
  haulId: string,
  name: option<string>,
  startedAt: string,
  doneAt: option<string>,
  emailedAt: option<string>,
  costUsd: float,
  stopReason: option<string>,
  emailNote: option<string>,
}

type sceneStatus = Queued | Running | Done | Failed

type scene = {
  sceneId: string,
  haulId: string,
  clientId: string,
  status: sceneStatus,
  photoPath: string,
  error: option<string>,
  costUsd: option<float>,
  claudeMs: option<float>,
  otherCount: option<int>,
  createdAt: string,
}

type find = {
  findId: string,
  sceneId: string,
  model: string,
  fixture: bool,
  name: string,
  query: string,
  where: option<string>,
  estimateLowUsd: float,
  estimateHighUsd: float,
  confidence: float,
  category: option<string>,
  promptVersion: string,
  ebayJson: option<string>,
  paidUsd: option<float>,
  soldUsd: option<float>,
  soldOn: option<string>,
  soldWhere: option<string>,
  createdAt: string,
  size: string,
  box: option<Types.box>,
}

type counts = {
  queued: int,
  running: int,
  done: int,
  failed: int,
}

// -- Params -----------------------------------------------------------------

let optText = (v: option<string>): Sqlite.param =>
  switch v {
  | Some(s) => Sqlite.Text(s)
  | None => Sqlite.Null
  }

let optNum = (v: option<float>): Sqlite.param =>
  switch v {
  | Some(n) => Sqlite.Num(n)
  | None => Sqlite.Null
  }

let optInt = (v: option<int>): Sqlite.param =>
  switch v {
  | Some(n) => Sqlite.Num(Int.toFloat(n))
  | None => Sqlite.Null
  }

let boolNum = (b: bool): Sqlite.param => Sqlite.Num(b ? 1.0 : 0.0)

// -- Status <-> text ----------------------------------------------------------

let statusToString = (status: sceneStatus): string =>
  switch status {
  | Queued => "queued"
  | Running => "running"
  | Done => "done"
  | Failed => "failed"
  }

let statusFromString = (s: string): option<sceneStatus> =>
  switch s {
  | "queued" => Some(Queued)
  | "running" => Some(Running)
  | "done" => Some(Done)
  | "failed" => Some(Failed)
  | _ => None
  }

// A bool column is stored as INTEGER 0/1, so node:sqlite hands the row back
// with a JS number for it, not a JS boolean. JSON.Decode.bool would reject
// that, so decode it as a number and compare.
let boolFromIntField = (json: JSON.t, key: string): option<bool> =>
  Json.floatField(json, key)->Option.map(n => n != 0.0)

// -- Row decoders -------------------------------------------------------------

let decodeHaul = (json: JSON.t): option<haul> =>
  switch (Json.stringField(json, "haulId"), Json.stringField(json, "startedAt"), Json.floatField(json, "costUsd")) {
  | (Some(haulId), Some(startedAt), Some(costUsd)) =>
    Some({
      haulId,
      name: Json.stringField(json, "name"),
      startedAt,
      doneAt: Json.stringField(json, "doneAt"),
      emailedAt: Json.stringField(json, "emailedAt"),
      costUsd,
      stopReason: Json.stringField(json, "stopReason"),
      emailNote: Json.stringField(json, "emailNote"),
    })
  | _ => None
  }

let decodeScene = (json: JSON.t): option<scene> =>
  switch (
    Json.stringField(json, "sceneId"),
    Json.stringField(json, "haulId"),
    Json.stringField(json, "clientId"),
    Json.stringField(json, "status")->Option.flatMap(statusFromString),
    Json.stringField(json, "photoPath"),
    Json.stringField(json, "createdAt"),
  ) {
  | (Some(sceneId), Some(haulId), Some(clientId), Some(status), Some(photoPath), Some(createdAt)) =>
    Some({
      sceneId,
      haulId,
      clientId,
      status,
      photoPath,
      error: Json.stringField(json, "error"),
      costUsd: Json.floatField(json, "costUsd"),
      claudeMs: Json.floatField(json, "claudeMs"),
      otherCount: Json.intField(json, "otherCount"),
      createdAt,
    })
  | _ => None
  }

let decodeFind = (json: JSON.t): option<find> =>
  switch (
    Json.stringField(json, "findId"),
    Json.stringField(json, "sceneId"),
    Json.stringField(json, "model"),
    boolFromIntField(json, "fixture"),
    Json.stringField(json, "name"),
    Json.stringField(json, "query"),
    Json.floatField(json, "estimateLowUsd"),
    Json.floatField(json, "estimateHighUsd"),
    Json.floatField(json, "confidence"),
    Json.stringField(json, "promptVersion"),
    Json.stringField(json, "createdAt"),
  ) {
  | (
      Some(findId),
      Some(sceneId),
      Some(model),
      Some(fixture),
      Some(name),
      Some(query),
      Some(estimateLowUsd),
      Some(estimateHighUsd),
      Some(confidence),
      Some(promptVersion),
      Some(createdAt),
    ) =>
    // All four box columns present means the find was stored with a valid
    // box (Box.decode already dropped a degenerate one before insertFind);
    // any other combination, including a pre-migration row, is None.
    let box = switch (
      Json.intField(json, "boxX1"),
      Json.intField(json, "boxY1"),
      Json.intField(json, "boxX2"),
      Json.intField(json, "boxY2"),
    ) {
    | (Some(x1), Some(y1), Some(x2), Some(y2)) => Some({Types.x1, y1, x2, y2})
    | _ => None
    }
    Some({
      findId,
      sceneId,
      model,
      fixture,
      name,
      query,
      where: Json.stringField(json, "where"),
      estimateLowUsd,
      estimateHighUsd,
      confidence,
      category: Json.stringField(json, "category"),
      promptVersion,
      ebayJson: Json.stringField(json, "ebayJson"),
      paidUsd: Json.floatField(json, "paidUsd"),
      soldUsd: Json.floatField(json, "soldUsd"),
      soldOn: Json.stringField(json, "soldOn"),
      soldWhere: Json.stringField(json, "soldWhere"),
      createdAt,
      size: Json.stringField(json, "size")->Option.getOr(""),
      box,
    })
  | _ => None
  }

// -- Open + schema ------------------------------------------------------------

let openAt = (path: string): t => {
  let db = Sqlite.make(path)

  Sqlite.exec(
    db,
    `CREATE TABLE IF NOT EXISTS hauls (
      haulId TEXT PRIMARY KEY,
      name TEXT,
      startedAt TEXT NOT NULL,
      doneAt TEXT,
      emailedAt TEXT,
      costUsd REAL NOT NULL DEFAULT 0,
      stopReason TEXT,
      emailNote TEXT
    )`,
  )

  Sqlite.exec(
    db,
    `CREATE TABLE IF NOT EXISTS scenes (
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
  Sqlite.exec(db, `CREATE INDEX IF NOT EXISTS idx_scenes_haul_status ON scenes (haulId, status)`)

  Sqlite.exec(
    db,
    `CREATE TABLE IF NOT EXISTS finds (
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
      createdAt TEXT NOT NULL,
      size TEXT,
      boxX1 INTEGER,
      boxY1 INTEGER,
      boxX2 INTEGER,
      boxY2 INTEGER
    )`,
  )
  Sqlite.exec(db, `CREATE INDEX IF NOT EXISTS idx_finds_scene ON finds (sceneId)`)

  // A DB from before item boxes or the size field has a `finds` table
  // missing those columns. CREATE TABLE IF NOT EXISTS above is a no-op on
  // an existing table, so check PRAGMA table_info and add any column it
  // doesn't already list.
  let findsCols =
    Sqlite.all(Sqlite.prepare(db, `PRAGMA table_info(finds)`), [])->Array.filterMap(row =>
      Json.stringField(row, "name")
    )
  let hasCol = (name: string): bool => Array.some(findsCols, c => c == name)
  if !hasCol("size") {
    Sqlite.exec(db, `ALTER TABLE finds ADD COLUMN size TEXT`)
  }
  if !hasCol("boxX1") {
    Sqlite.exec(db, `ALTER TABLE finds ADD COLUMN boxX1 INTEGER`)
  }
  if !hasCol("boxY1") {
    Sqlite.exec(db, `ALTER TABLE finds ADD COLUMN boxY1 INTEGER`)
  }
  if !hasCol("boxX2") {
    Sqlite.exec(db, `ALTER TABLE finds ADD COLUMN boxX2 INTEGER`)
  }
  if !hasCol("boxY2") {
    Sqlite.exec(db, `ALTER TABLE finds ADD COLUMN boxY2 INTEGER`)
  }

  db
}

let close = (db: t): unit => Sqlite.close(db)

// -- Hauls --------------------------------------------------------------------

let getHaul = (db: t, haulId: string): option<haul> => {
  let stmt = Sqlite.prepare(db, "SELECT * FROM hauls WHERE haulId = ?")
  Sqlite.get(stmt, [Sqlite.Text(haulId)])->Option.flatMap(decodeHaul)
}

let createHaul = (db: t, ~haulId: string, ~name: option<string>, ~now: string): haul => {
  let stmt = Sqlite.prepare(
    db,
    "INSERT INTO hauls (haulId, name, startedAt, costUsd) VALUES (?, ?, ?, 0)",
  )
  Sqlite.run(stmt, [Sqlite.Text(haulId), optText(name), Sqlite.Text(now)])->ignore
  {
    haulId,
    name,
    startedAt: now,
    doneAt: None,
    emailedAt: None,
    costUsd: 0.0,
    stopReason: None,
    emailNote: None,
  }
}

let addHaulCost = (db: t, ~haulId: string, delta: float): float => {
  let stmt = Sqlite.prepare(db, "UPDATE hauls SET costUsd = costUsd + ? WHERE haulId = ?")
  Sqlite.run(stmt, [Sqlite.Num(delta), Sqlite.Text(haulId)])->ignore
  switch getHaul(db, haulId) {
  | Some(h) => h.costUsd
  | None => delta
  }
}

// Keeps the first reason: a second call with the stop reason already set is
// a no-op.
let stopHaul = (db: t, ~haulId: string, ~reason: string): unit => {
  let stmt = Sqlite.prepare(
    db,
    "UPDATE hauls SET stopReason = ? WHERE haulId = ? AND stopReason IS NULL",
  )
  Sqlite.run(stmt, [Sqlite.Text(reason), Sqlite.Text(haulId)])->ignore
}

let markDone = (db: t, ~haulId: string, ~now: string): unit => {
  let stmt = Sqlite.prepare(db, "UPDATE hauls SET doneAt = ? WHERE haulId = ?")
  Sqlite.run(stmt, [Sqlite.Text(now), Sqlite.Text(haulId)])->ignore
}

let markEmailed = (db: t, ~haulId: string, ~now: string, ~note: option<string>): unit => {
  let stmt = Sqlite.prepare(db, "UPDATE hauls SET emailedAt = ?, emailNote = ? WHERE haulId = ?")
  Sqlite.run(stmt, [Sqlite.Text(now), optText(note), Sqlite.Text(haulId)])->ignore
}

// -- Scenes ---------------------------------------------------------------------

let sceneByClient = (db: t, ~haulId: string, ~clientId: string): option<scene> => {
  let stmt = Sqlite.prepare(db, "SELECT * FROM scenes WHERE haulId = ? AND clientId = ?")
  Sqlite.get(stmt, [Sqlite.Text(haulId), Sqlite.Text(clientId)])->Option.flatMap(decodeScene)
}

// Inserts as queued. If clientId already exists for that haul, the existing
// row is returned unchanged (a retried upload then costs nothing).
let addScene = (
  db: t,
  ~haulId: string,
  ~clientId: string,
  ~sceneId: string,
  ~photoPath: string,
  ~now: string,
): scene =>
  switch sceneByClient(db, ~haulId, ~clientId) {
  | Some(existing) => existing
  | None => {
      let stmt = Sqlite.prepare(
        db,
        "INSERT INTO scenes (sceneId, haulId, clientId, status, photoPath, createdAt) VALUES (?, ?, ?, 'queued', ?, ?)",
      )
      Sqlite.run(
        stmt,
        [
          Sqlite.Text(sceneId),
          Sqlite.Text(haulId),
          Sqlite.Text(clientId),
          Sqlite.Text(photoPath),
          Sqlite.Text(now),
        ],
      )->ignore
      {
        sceneId,
        haulId,
        clientId,
        status: Queued,
        photoPath,
        error: None,
        costUsd: None,
        claudeMs: None,
        otherCount: None,
        createdAt: now,
      }
    }
  }

// Oldest queued scene whose haul has no stopReason. rowid breaks ties when
// two scenes share a createdAt timestamp, keeping insertion order (FIFO).
let nextQueued = (db: t): option<scene> => {
  let stmt = Sqlite.prepare(
    db,
    `SELECT scenes.* FROM scenes
     JOIN hauls ON hauls.haulId = scenes.haulId
     WHERE scenes.status = 'queued' AND hauls.stopReason IS NULL
     ORDER BY scenes.createdAt ASC, scenes.rowid ASC
     LIMIT 1`,
  )
  Sqlite.get(stmt, [])->Option.flatMap(decodeScene)
}

let setStatus = (db: t, ~sceneId: string, status: sceneStatus): unit => {
  let stmt = Sqlite.prepare(db, "UPDATE scenes SET status = ? WHERE sceneId = ?")
  Sqlite.run(stmt, [Sqlite.Text(statusToString(status)), Sqlite.Text(sceneId)])->ignore
}

// running -> queued (a restart then loses no photo). Returns the count.
let resetRunning = (db: t): int => {
  let stmt = Sqlite.prepare(db, "UPDATE scenes SET status = 'queued' WHERE status = 'running'")
  let result = Sqlite.run(stmt, [])
  Float.toInt(result.changes)
}

let finishScene = (
  db: t,
  ~sceneId: string,
  ~costUsd: float,
  ~claudeMs: float,
  ~otherCount: option<int>,
): unit => {
  let stmt = Sqlite.prepare(
    db,
    "UPDATE scenes SET status = 'done', costUsd = ?, claudeMs = ?, otherCount = ? WHERE sceneId = ?",
  )
  Sqlite.run(
    stmt,
    [Sqlite.Num(costUsd), Sqlite.Num(claudeMs), optInt(otherCount), Sqlite.Text(sceneId)],
  )->ignore
}

let failScene = (
  db: t,
  ~sceneId: string,
  ~error: string,
  ~costUsd: option<float>,
  ~claudeMs: option<float>,
): unit => {
  let stmt = Sqlite.prepare(
    db,
    "UPDATE scenes SET status = 'failed', error = ?, costUsd = ?, claudeMs = ? WHERE sceneId = ?",
  )
  Sqlite.run(
    stmt,
    [Sqlite.Text(error), optNum(costUsd), optNum(claudeMs), Sqlite.Text(sceneId)],
  )->ignore
}

let scenesOf = (db: t, haulId: string): array<scene> => {
  let stmt = Sqlite.prepare(
    db,
    "SELECT * FROM scenes WHERE haulId = ? ORDER BY createdAt ASC, rowid ASC",
  )
  Sqlite.all(stmt, [Sqlite.Text(haulId)])->Array.filterMap(decodeScene)
}

let counts = (db: t, haulId: string): counts => {
  let scenes = scenesOf(db, haulId)
  let countOf = status => Array.filter(scenes, s => s.status == status)->Array.length
  {
    queued: countOf(Queued),
    running: countOf(Running),
    done: countOf(Done),
    failed: countOf(Failed),
  }
}

// -- Finds ----------------------------------------------------------------------

let insertFind = (db: t, find: find): unit => {
  let stmt = Sqlite.prepare(
    db,
    `INSERT INTO finds (
      findId, sceneId, model, fixture, name, query, "where",
      estimateLowUsd, estimateHighUsd, confidence, category, promptVersion,
      ebayJson, paidUsd, soldUsd, soldOn, soldWhere, createdAt, size,
      boxX1, boxY1, boxX2, boxY2
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
  Sqlite.run(
    stmt,
    [
      Sqlite.Text(find.findId),
      Sqlite.Text(find.sceneId),
      Sqlite.Text(find.model),
      boolNum(find.fixture),
      Sqlite.Text(find.name),
      Sqlite.Text(find.query),
      optText(find.where),
      Sqlite.Num(find.estimateLowUsd),
      Sqlite.Num(find.estimateHighUsd),
      Sqlite.Num(find.confidence),
      optText(find.category),
      Sqlite.Text(find.promptVersion),
      optText(find.ebayJson),
      optNum(find.paidUsd),
      optNum(find.soldUsd),
      optText(find.soldOn),
      optText(find.soldWhere),
      Sqlite.Text(find.createdAt),
      Sqlite.Text(find.size),
      optInt(find.box->Option.map(b => b.x1)),
      optInt(find.box->Option.map(b => b.y1)),
      optInt(find.box->Option.map(b => b.x2)),
      optInt(find.box->Option.map(b => b.y2)),
    ],
  )->ignore
}

// The finds of one haul, through scenes.haulId.
let findsOf = (db: t, haulId: string): array<find> => {
  let stmt = Sqlite.prepare(
    db,
    `SELECT finds.* FROM finds
     JOIN scenes ON scenes.sceneId = finds.sceneId
     WHERE scenes.haulId = ?
     ORDER BY finds.createdAt ASC, finds.rowid ASC`,
  )
  Sqlite.all(stmt, [Sqlite.Text(haulId)])->Array.filterMap(decodeFind)
}
