# Haul map, place slice: brain build hand-off

Working tree: /Users/dwight/code/reflip/.claude/worktrees/sharp-borg-0aed69
Branch: claude/haul-map-place (from origin/main e9c765e)

Verification command: `npm test`

## Steps

- [x] 0. Baseline: `npm test` green before any edit (929 ok, 0 not ok) — no install needed, node_modules present
- [x] 1. Types.res: placeSource, place, encodePlace. Also required (to keep the
      tree compiling, since encodeHaulStatus now requires a `place` field on
      every `Types.haulStatus` literal): Shared.res's decodeHaulStatus,
      HaulStatus.res's build, and src/tests/AppStateTest.res's
      sampleHaulStatus all got `place: None` placeholders, marked with
      `TODO(haul-map step N)` comments pointing at the real step that
      replaces them (Shared.res's decode -> step 5 real decodePlace once
      Place.res exists; HaulStatus.res -> step 3 once Store.haul carries
      place). `npm test`: 929 ok, 0 not ok (unchanged from baseline).
      Commit: edd3e07
- [x] 2. src/Place.res: decodeInput, choose; src/tests/PlaceTest.res in AllTests.
      Implemented per the design notes below, no deviations. `npm test`: 942
      ok, 0 not ok (929 baseline + 13 new). Commit: fdfb73e
- [x] 3. Store.res: hauls table place columns, migration, Store.haul.place, setPlace; StoreTest.
      Also replaced HaulStatus.res's `place: None` placeholder with the real
      `haul.place`. No deviations from the design notes. `npm test`: 950 ok,
      0 not ok (942 baseline + 8 new). Commit: 3bb2ada
- [x] 4. Server.res: POST /api/hauls/:id/place; ServerTest. Implemented per the
      design notes below, no deviations (handleSetPlace's `config` param is
      unused in the body, so it is `_config` to keep the build warning-free).
      `npm test`: 962 ok, 0 not ok (950 baseline + 12 new). Commit: e2f6208
- [x] 5. Haul status reply: Shared.decodeHaulStatus real decode (replace the
      `place: None` placeholder added in step 1) using a new `decodePlace`
      helper in Shared.res (reuses `Place.sourceFromString`/`sourceToString`
      from step 2 — no cycle, Place.res only depends on Types.res).
      SharedDecodeTest round trip (with a place, without a place, and with
      the "place" key absent entirely -> None). Types.haulStatus/encodeHaulStatus
      already done in step 1. Implemented per the design notes, no deviations
      (`sourceToString` ended up unused by `decodePlace` itself — only
      `sourceFromString` is needed to go JSON -> Types.placeSource — but it
      stays used elsewhere, by Place.res and Store.res). `npm test`: 965 ok,
      0 not ok (962 baseline + 3 new). Commit: 50dd213
- [x] 6. HaulWorker.requestBodyFor pure extraction; runScene uses it, behavior unchanged.
      Commit d0d351c. `prepared(t, scene)` gives the model, the photo and the mode to both
      `requestBodyFor` and `runScene`. `ClaudeClient.send` still builds the body inside, from
      the same three values, so every store value reaches both through `prepared`.
- [x] 7. GuardTest.res: place stays out of Claude request body and out of the haul digest.
      Commit 4765ce7. Also d3d85a4: the place route caps its body at 4096 bytes (413 above).
      `npm test`: 973 ok, 0 not ok.

## Design notes for the remaining steps (so a fresh agent can pick this up cold)

**Place.res** (pure, no Node imports, depends only on Types.res):
- `type input = {lat: float, lon: float, accuracyM: option<float>, source: Types.placeSource}`
- `sourceToString`/`sourceFromString` map `Types.placeSource <-> "gps"|"pin"`. Reused by
  Store.res (decodeHaul, setPlace) and Shared.res (decodePlace).
- `decodeInput(json)`: lat/lon/source required via `Json.floatField`/`Json.stringField`
  (a wrong-typed value, e.g. a string lat, already decodes to `None` there, which becomes
  the generic "lat, lon and source are required" error — covers the "string lat fails" case
  for free). Bounds: lat in [-90,90], lon in [-180,180], inclusive both ends. source must be
  "gps" or "pin" via sourceFromString, else Error. accuracyM: `Json.floatField(json,
  "accuracyM")` — `Some(a) if a < 0.0` -> Error; `Some(a)` -> `Ok` with that value; `None` ->
  Error for Gps ("gps place needs accuracyM"), Ok(None) for Pin. This makes a non-numeric or
  null accuracyM behave the same as absent (matches spec text literally: "accuracyM is 0 or
  more, or null for a pin" — only two states named).
- `choose(~stored: option<Types.place>, ~incoming: Types.place): Types.place`:
  `switch (stored, incoming.source) { | (Some({source: Pin} as pin), Gps) => pin | _ => incoming }`
- PlaceTest.res cases (add to AllTests.res in the sync section, near GuardTest/StoreTest):
  lat=90 valid (pair with a valid pin+null combo), lat=90.0001 invalid, lon=-180 valid,
  lon=-180.1 invalid, gps+accuracyM=null -> Error, pin+accuracyM=null -> Ok, accuracyM=-5 ->
  Error, lat as a JSON string -> Error, source="wifi" -> Error. choose: (no stored, incoming
  gps) -> incoming; (stored pin, incoming gps) -> stored pin kept; (stored gps, incoming pin)
  -> incoming pin wins; (stored pin, incoming pin) -> incoming (new pin) wins.

**Store.res**:
- CREATE TABLE hauls: add `lat REAL, lon REAL, placeAccuracyM REAL, placeSource TEXT, placeAt TEXT`
  as trailing columns (comma after `emailNote TEXT`).
- openAt: same PRAGMA table_info(hauls) migration pattern as the existing finds/scenes blocks,
  right after the CREATE TABLE hauls block (before the scenes CREATE TABLE, or anywhere before
  `db` is returned) — ALTER TABLE hauls ADD COLUMN for each of the 5 names if missing.
- `haul` type: add `place: option<Types.place>`.
- `decodeHaul`: build `place` from `(Json.floatField "lat", Json.floatField "lon",
  Json.stringField "placeSource", Json.stringField "placeAt")` all Some, then
  `Place.sourceFromString(sourceStr)` — if any missing or source unparsable, `place = None`.
  `accuracyM = Json.floatField(json, "placeAccuracyM")` (independently optional).
- `setPlace(db, ~haulId, ~place: Types.place): option<Types.place>`:
  `getHaul` -> None if unknown; else `Place.choose(~stored=haul.place, ~incoming=place)`,
  UPDATE hauls SET lat=?, lon=?, placeAccuracyM=?, placeSource=?, placeAt=? WHERE haulId=?
  (use `optNum`/`Sqlite.Text(Place.sourceToString(chosen.source))`), return `Some(chosen)`.
- Then replace HaulStatus.res's `place: None` TODO with `place: haul.place`.
- StoreTest.res new sections: migrate an old-schema hauls table (same hand-built
  Sqlite.exec + PRAGMA pattern as the existing finds/scenes migration tests, ~line 298 and
  ~line 404) missing the 5 place columns, then Store.openAt it and confirm a place round-trips;
  a round trip of setPlace on a normal haul; gps-after-pin keeps the pin (via setPlace called
  twice); setPlace on an unknown haulId returns None.

**Server.res**:
- `haulRoute` type: add `SetPlace(string)`.
- `parseHaulPath`, the `("POST", 4)` branch: add `else if c == "place" { Some(SetPlace(id)) }`
  alongside the existing `scenes`/`done` checks.
- `route`: add `| Some(SetPlace(haulId)) => await handleSetPlace(config, store, haulId, req, res)`.
- `handleSetPlace`: read body via `Node.HttpServer.readBody(req)`, reuse `maxPhotoBytes` (15 MB)
  as the size cap (413 over that, matching the pattern in handleAddScene) — reuses the existing
  size-limit constant per the brief, even though a place body is tiny. Then
  `JSON.parseOrThrow` (catch `JsExn(_)` -> 400 "invalid JSON body"), `Place.decodeInput` (Error
  -> 400 with that reason as `error`), else build `now = Date.toISOString(Date.make())`,
  `Types.place = {lat: input.lat, lon: input.lon, accuracyM: input.accuracyM,
  source: input.source, at: now}`, `Store.setPlace(store, ~haulId, ~place)` — None -> 404 "no
  such haul", Some(stored) -> 200 `Json.obj([("haulId", Json.str(haulId)), ("place",
  Types.encodePlace(stored))])`. No logging of the body or of lat/lon anywhere in this handler
  (CLAUDE.md privacy rule — "Log no body and no coordinates").
- ServerTest.res: POST .../place with a valid gps body -> 200 with the place in the reply; lat
  91 -> 400; malformed JSON -> 400; unknown haul id -> 404; set a pin, then POST a gps body on
  the same haul -> 200 but the reply's place is still the pin (source "pin").

**HaulWorker.res** (step 6): factor `runScene`'s current inline "read photo -> JpegSize.dimensions
-> base64 -> model -> mode" into a private helper (e.g. `prepared(t, scene): result<(string,
string, ClaudeClient.mode), string>` returning (model, imageBase64, mode), Error with the same
two messages runScene already uses for a missing photo / unreadable size). `requestBodyFor(t,
scene) = prepared(t, scene)->Result.map(((model, imageBase64, mode)) =>
ClaudeClient.buildRequestBody(~model, ~imageBase64, ~structuredOutput=t.config.structuredOutput,
~mode))`. `runScene` calls `prepared` instead of inlining those steps, `Error(msg) =>
Failed(msg, None, None)` (same as today), `Ok((model, imageBase64, mode)) => switch await
ClaudeClient.call(~config=t.config, ~model, ~imageBase64, ~mode) { ...unchanged rest... }`. This
keeps `ClaudeClient.call`/`send` (400 retry, timeout, every error branch) completely untouched —
`requestBodyFor`'s output is provably identical to what `send` independently rebuilds, since both
call the same pure `buildRequestBody` with the same inputs.

**GuardTest.res** (step 7): new section after the existing haul-mode guard checks. Build a
`Store.openAt(":memory:")`, `Store.createHaul`, `Store.addScene` with `photoPath` pointed straight
at `tests/fixtures/table.jpg` (no need to copy it into a data dir — HaulWorker just
`Node.Fs.readFileBuffer`s whatever path is on the scene row), `Store.setPlace` with lat
47.6180431, lon -122.3514229, accuracyM 13.37, source Gps. First assert
`JSON.stringify(Json.obj([("place", ...Types.encodePlace of the stored haul's place...)]))`
contains "47.618" (proves the search methodology can fail). Then build a minimal `Config.t`
literal (copy the shape from `HaulEmailTest.res`'s `baseConfig`, `fixtures: true`,
`haulGemMinUsd: 20.0`, etc.), `HaulWorker.make(~config, ~store, ~onDrained=_ =>
Promise.resolve())`, call `HaulWorker.requestBodyFor(worker, scene)`, `JSON.stringify` the `Ok`
body, and assert it excludes "47.618", "122.351", "13.37". Then build the digest via
`HaulEmail.digestInputOf(config, haul, scenes, finds, counts, Dict.make())` (finds can be `[]` —
`digestGemsOf` handles empty arrays fine) + `Digest.make(digestInput, ~cidFor=id => id)`,
concatenate subject+text+html, and assert the same three strings are absent there too.

## Log

(attempts and errors go here — none yet for step 1, it went clean once the
downstream `place: None` placeholders were added)

Steps 2 and 3 also went clean, no failed attempts. A TURN-COUNTER note
arrived (turn 60) right after step 3's hand-off commit, while only
reading src/Server.res's `resq list` output for step 4 reconnaissance —
no step-4 edits were made. Server.res facts for the next agent: haulRoute
type at L122, parseHaulPath L124-163, route dispatch L594-690,
handleAddScene (body-read + size-limit pattern to reuse) L289-348,
maxPhotoBytes L214, handleMarkDone (a same-shape simple POST handler)
L384-399, handleGetHaul L350-355. Step 4 is otherwise unstarted.

## Page

The brain half above is done. This section covers the phone page's half of
the place slice: `POST /api/hauls/:id/place`, the haul status reply's
`place` field, and `Shared.decodePlace` all already exist and are not
touched here.

- [ ] P1. WebApi.res: typed geolocation bindings — an abstract `geolocation`
      type, `@val @scope("navigator") external geolocation:
      Nullable.t<geolocation>`, a `@send` `getCurrentPosition` taking
      (success, error, options), and records for the coords (latitude,
      longitude, accuracy), the position (coords), the error (code) and the
      options (enableHighAccuracy, timeout, maximumAge).
- [ ] P2. AppState.res, pure, with AppStateTest cases: `placeFix`, a `place`
      field on the model with states not asked / asking / sending(fix) /
      not sent(fix) / saved(option<fix>) / denied / failed (constructor
      names disjoint from every msg name); msgs asked (Try again),
      fixed(fix), denied, unavailable, sent(Types.place), send failed,
      rejected; StartHaul sets asking, NewHaul resets to not asked;
      `placeKey`/`parsePlaceKey` (and confirm `parseQueueKey` still ignores
      a place key); `encodePlaceBody`/`decodePlaceBody`; `placeLine`.
- [ ] P3. Api.res: `postPlace(haulId, body)` → `Sent(Types.place)` on 200,
      `Rejected(status)` on 400/404, `NotSent(reason)` otherwise (bad
      status, network error, or a 200 whose place does not decode).
- [ ] P4. App.res effects: `askPlace` (geolocation → dispatch → resolves
      `option<placeFix>`), `sendPlace` (outbox write → POST → dispatch);
      Start haul asks for the position in parallel with the haul start and
      pairs each ask with its own start (drops the fix if the start fails);
      Try again re-asks then sends against the current haul id from
      `rewind.live`; on load, after the haul restore, every `place|<id>`
      outbox entry is sent, dispatching only for the current haul.
- [ ] P5. View: HaulView shows `placeLine`'s text near `haul-store-name`
      in the existing quiet meta style, with a small "Try again" text
      button when `tryAgain` is true. New CSS goes in `src/web/scan.css`.

Verification for every step below: `npm test` (build + AllTests). Commit
each step once green, then tick it here with its SHA.

### Log

(attempts and errors for the Page steps go here)
