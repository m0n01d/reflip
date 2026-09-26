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
keeps `ClaudeClient.call`/`send` (400 retry, timeout, every error branch) completely untouched.

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

- [x] P1. WebApi.res: typed geolocation bindings — an abstract `geolocation`
      type, `@val @scope("navigator") external geolocation:
      Nullable.t<geolocation>`, a `@send` `getCurrentPosition` taking
      (success, error, options), and records for the coords (latitude,
      longitude, accuracy), the position (coords), the error (code) and the
      options (enableHighAccuracy, timeout, maximumAge). `npm test`: 973
      ok, 0 not ok (unchanged — new bindings, not yet called). Commit:
      35c4c96
- [x] P2. AppState.res, pure, with AppStateTest cases: `placeFix`, a `place`
      field on the model with states not asked / asking / sending(fix) /
      not sent(fix) / saved(option<fix>) / denied / failed (constructor
      names disjoint from every msg name); msgs asked (Try again),
      fixed(fix), denied, unavailable, sent(Types.place), send failed,
      rejected; StartHaul sets asking, NewHaul resets to not asked;
      `placeKey`/`parsePlaceKey` (and confirm `parseQueueKey` still ignores
      a place key); `encodePlaceBody`/`decodePlaceBody`; `placeLine`.
      Implemented per the design notes below, no deviations except one:
      `placeLine`'s brief signature `option<{text: string, tryAgain:
      bool}>` does not parse in ReScript 12 (inline record types are only
      allowed inside a variant constructor or nested in another record
      type) — added a two-field named type `placeLineText` and return
      `option<placeLineText>` instead; every call site still reads
      `Some({text: ..., tryAgain: ...})`. Msg names: `PlaceAskAgain`
      ("asked (Try again)"), `PlaceFixed(fix)`, `PlaceGeoDenied`
      ("denied"), `PlaceUnavailable`, `PlaceSent(Types.place)`,
      `PlaceSendFailed`, `PlaceRejected` — kept distinct from the
      `Place{NotAsked,Asking,Sending,NotSent,Saved,Denied,Failed}` state
      constructors per the brief. `PlaceSent`/`PlaceRejected` both read
      the fix already in flight via a new small helper `fixOfPlaceState`.
      `npm test`: 1001 ok, 0 not ok (973 baseline + 28 new). Commit:
      4deb3b4

## Design notes for P3-P5 (so a fresh agent can pick this up cold)

**Api.res (P3)**: add near the other haul-mode functions (postHaul,
getHaulStatus, postHaulDone). Signature: `postPlace(haulId: string, body:
string): promise<placeResult>` where `type placeResult = Sent(Types.place)
| Rejected(int) | NotSent(string)`. Body: `fetchString` POST to
`/api/hauls/` ++ haulId ++ `/place` with `Content-Type: application/json`,
same shape as `postHaulDone`/`postHaul`. On `responseOk` decode the JSON's
"place" field with `Shared.decodePlace` (already exists) — `Some(p) =>
Sent(p)`, `None => NotSent("could not read the reply: missing place")`. On
not-ok: status 400 or 404 -> `Rejected(status)`; anything else -> `NotSent(await
readErrorReason(resp))`. Network error (`JsExn`) -> `NotSent("could not
reach the server")`.

**App.res (P4)**: `askPlace(dispatch): promise<option<AppState.placeFix>>`
— `WebApi.geolocation->Nullable.toOption`, `None` dispatches
`PlaceUnavailable` and resolves `None`. `Some(geo)`: wrap
`WebApi.getCurrentPosition` in `Promise.make((resolve, _reject) => ...)`
exactly like `Resize.res`'s `toBlobRaw` wrapper (resolve an `Ok`/`Error`
so both callbacks funnel through one await); measure `tookMs` with
`Date.now()` before/after (not `WebApi.now()`/performance.now — the brief
is explicit: "Measure tookMs with Date.now"); options `{enableHighAccuracy:
true, timeout: 15000, maximumAge: 60000}`; error code 1 ->
`PlaceGeoDenied`, any other code -> `PlaceUnavailable`; success -> build an
`AppState.placeFix` from `pos.coords`, dispatch `PlaceFixed(fix)`, resolve
`Some(fix)`.

`sendPlace(dispatch, haulId, fix)`: `await
WebApi.idbSetString(AppState.placeKey(haulId),
AppState.encodePlaceBody(fix))`, then `Api.postPlace`. `Sent(place) =>`
delete the outbox key, `dispatch(AppState.PlaceSent(place))`.
`Rejected(_) =>` delete the outbox key (a resend cannot succeed),
`dispatch(AppState.PlaceRejected)`. `NotSent(_) =>` keep the key,
`dispatch(AppState.PlaceSendFailed)`. For "send the others silently" on
load (below), call this same function with `dispatch = _ => ()`.

Wire into `onStartHaul` (around App.res L1332): change `startHaul` to
return `promise<option<string>>` (the new haulId on success, `None` on
`HaulStartFailed` — it already dispatches either way, just add `Some(...)`
/`None` as the resolved value after each dispatch). Kick off `let started
= startHaul(...)` and `let asked = askPlace(dispatch)` in the same
handler (both start immediately — this is what "must not wait" means),
then `(async () => { let haulId = await started; let fix = await asked;
switch (haulId, fix) { | (Some(id), Some(f)) => await sendPlace(dispatch,
id, f) | _ => () } })()->Promise.ignore`. A failed start naturally drops
the fix (the `_ => ()` branch) with no extra state needed — `HaulStartFailed`
already routes the view back to `NoHaul`/`ScanShell`, where `place` is not
rendered, and the next `StartHaul` resets `place` to `PlaceAsking` anyway.

A "Try again" handler (new, wired to the P5 button): `let
onPlaceTryAgain = (_event) => { dispatch(AppState.PlaceAskAgain);
(async () => { let fix = await askPlace(dispatch); switch (fix,
AppState.haulStatusOf(rewind.live.haul)) { | (Some(f), Some(status)) =>
await sendPlace(dispatch, status.haulId, f) | _ => () } })()
->Promise.ignore }` — reads `rewind.live`, never `model`, per the
rewind rule in this repo's CLAUDE.md. Pass it down to `HaulView` as a new
prop, e.g. `~onPlaceTryAgain`.

On-load restore (new function near `restoreHaul`/`restoreQueueFor`, called
from the same `React.useEffect0` mount effect right after `restoreHaul`
resolves — needs sequencing, e.g. `restoreHaul(dispatch)->then(() =>
restorePlaces(dispatch))`, since it needs to know the just-restored current
haul id): `restorePlaces(dispatch)` reads `WebApi.idbKeysUnknown()`, maps
through `unknownToText`, `Array.filterMap(AppState.parsePlaceKey)` (each
match is a bare haulId, unlike `parseQueueKey`'s pair), then for each
haulId reads `WebApi.idbGetUnknown(AppState.placeKey(haulId))`, decodes
with `AppState.decodePlaceBody` (drop silently on `None`), and calls
`sendPlace` — pass the real `dispatch` only when
`Some(haulId) == AppState.haulStatusOf(model.haul)->Option.map(s =>
s.haulId)` (read via a snapshot taken once before the loop, e.g. inside
the `then` callback where the restored model is known), else `_ => ()`.

**View (P5)**: in `HaulView.make` (src/web/App.res, module starts L746),
add `~onPlaceTryAgain: unit => unit` to the props list, and read
`model.place` (already passed via the existing `~model` prop — no new
prop needed for the state) plus `status.place` (already on
`Types.haulStatus`). Compute `let placeLineResult =
AppState.placeLine(model.place, status.place)` near the other
header-area `let`s (around L778, next to `storeName`). In the JSX, inside
`.scan-card-top-row`'s parent block, right after that row closes (after
L845's `</div>`, i.e. right after the `HaulClock`), render: `{switch
placeLineResult { | None => React.null | Some({text, tryAgain}) =>
<div className="haul-place-line"> <span> {React.string(text)} </span>
{tryAgain ? <button type_="button" className="haul-place-retry"
onClick={_ => onPlaceTryAgain()}> {React.string("Try again")} </button>
: React.null} </div> }}`. Note ReScript's JSX prop for the HTML `type`
attribute on `<button>` is `type_` (see other `<input type_=...>` uses
in this file, e.g. ScanShell/EbayBlock, if any — grep first). Wire the
new prop through at the call site (App.res L1387-1397,
`<HaulView model phase status ... />`) with `onPlaceTryAgain` (the
handler from P4). CSS: add `.haul-place-line` (quiet meta text — mirror
`.haul-stop-note`'s `color: var(--scan-mode-track); font-size: 13px;
line-height: 1.4;`, plus `margin-top: 2px; display: flex; align-items:
baseline; gap: 6px; flex-wrap: wrap;`) and `.haul-place-retry` (a small
text button: `background: none; border: none; padding: 0; font: inherit;
font-size: 13px; color: var(--scan-link); text-decoration: underline;
text-underline-offset: 2px; cursor: pointer;`) to `src/web/scan.css`,
near `.haul-store-name` (L1815) / `.haul-stop-note` (L1808).

After P4/P5 land, run `npm run build` and use dev-browser (or the iOS
Simulator's Safari, since this is a phone page — geolocation needs a
secure context, and `http://127.0.0.1` counts) to tap "Add photos" via
`FIXTURES=1 PORT=8787 npm start`, confirm the haul view shows a place
line (the browser will prompt for location permission — grant it for a
real "Place saved" line, or deny it to see "No place" — geolocation is not
in fixture mode's scope, it talks to the real browser API and the real
`/api/hauls/:id/place` route, which is already live per step 4 above).
Screenshot both the granted and the denied paths before calling P5 done.
- [x] P3 (commit 1362a73). Api.res: `postPlace(haulId, body)` → `Sent(Types.place)` on 200,
      `Rejected(status)` on 400/404, `NotSent(reason)` otherwise (bad
      status, network error, or a 200 whose place does not decode).
- [x] P4 (commit 630a10c, with P5). App.res effects: `askPlace` (geolocation → dispatch → resolves
      `option<placeFix>`), `sendPlace` (outbox write → POST → dispatch);
      Start haul asks for the position in parallel with the haul start and
      pairs each ask with its own start (drops the fix if the start fails);
      Try again re-asks then sends against the current haul id from
      `rewind.live`; on load, after the haul restore, every `place|<id>`
      outbox entry is sent, dispatching only for the current haul.
- [x] P5 (commit 630a10c). View: HaulView shows `placeLine`'s text near `haul-store-name`
      in the existing quiet meta style, with a small "Try again" text
      button when `tryAgain` is true. New CSS goes in `src/web/scan.css`.

Verification for every step below: `npm test` (build + AllTests). Commit
each step once green, then tick it here with its SHA.

### Log

(attempts and errors for the Page steps go here)

## Checks in a browser

- [x] C1. `scripts/place-check.mjs` in dev-browser: saved, a late haul id, the outbox after a
      reload, denied, failed then Try again, and the outbox on a done haul. Screenshots in
      `docs/shots/haul-map/`. Green at `2282342`.
- [x] C2. `node scripts/haul-smoke.mjs` passes. Green at `2282342`.

### Log

Wrote `scripts/place-check.mjs` (Node wrapper, copies `haul-smoke.mjs`'s
structure: build step, free port, throwaway `DATA_DIR`, `FIXTURES=1`, own
dev-browser instance `reflip-place`, one `PLACE_CHECK_RESULT` JSON line,
screenshots copied out of the dev-browser jail) and
`scripts/place-check.browser.js` (the five in-browser cases: saved, late
haul id, outbox-then-reload, denied, failed-then-Try-again). The sixth
case, privacy, lives in the `.mjs` wrapper itself, since it needs to read
the brain's own server-log file, which the dev-browser sandbox cannot
reach.

Neither file is committed yet — see "blocked" below, this is not a green
step.

**Gotcha found and worked around**: this dev-browser build's
`page.addInitScript` crashes the whole script with `QuickJS function
"__transport_receive" failed: expected object, got undefined`, reproduced
with a bare `page.addInitScript(() => {})` and no other calls (probed
2026-09-26). The brief's C1 spec calls for `addInitScript` in cases 4 and
5. Worked around by installing the `navigator.geolocation.getCurrentPosition`
override with a plain `page.evaluate` right after the page has loaded but
before the click that triggers the only `getCurrentPosition` call on that
load — `askPlace` only reads `navigator.geolocation` at click time, so the
ordering the brief needed from `addInitScript` (in place before the first
call) still holds. Worth folding into the CLAUDE.md dev-browser gotchas
once this lands.

**Blocked**: after that fix, every case still fails — the app never
renders past a blank `<div id="root">`. The browser's `pageerror` is
`TypeError: Cannot read properties of null (reading 'useState')`, the
classic "no live React dispatcher" symptom (invalid hook call / two React
copies). Root-caused by hand:

- `npm test` passes clean in this worktree (it does not touch the Vite
  bundle's runtime).
- `npm run build` (both `rescript build` and `vite build`) also succeeds
  with no errors and produces `dist/assets/index-*.js`.
- But `npm ls rescript-rewind` in this worktree prints `(empty)` —
  `rescript-rewind` (the `App.res` "Time-travel debugger (rewind)" section
  of this file, `Rewind.use` in `App.make`) is in `package.json` and
  `package-lock.json` but **is not actually present in `node_modules`**.
  `node_modules`'s own mtime (2026-09-25) predates whatever added that
  dependency to the lockfile, i.e. this worktree's `node_modules` is stale
  — exactly the gotcha this repo's own memory note already names
  (`~/.claude/projects/.../reflip-smoke-gotchas.md`: "A new worktree can
  hold an old `node_modules` from main... Run `npm install` after a
  checkout"), just for a different missing package than the one that note
  was written about (`idb-keyval` then, `rescript-rewind` now).
- **This is not new**: `node scripts/haul-smoke.mjs --skip-build --timeout 90`
  (C2's own verification command, pre-existing and unrelated to this
  session's edits) fails with the exact same `pageerror` and the exact
  same `getByRole('button', { name: 'Haul', exact: true })` timeout. So
  both C1 and C2 are blocked by the same pre-existing environment gap, not
  by anything wrong in `place-check.mjs`/`place-check.browser.js` or in
  the P1–P5 app code.

Per the brief ("If it is in the app, report it and do not fix the app")
and the turn-counter note that arrived while root-causing this, I stopped
here rather than running `npm install` myself. **Next step for whoever
picks this up**: run `npm install` in this worktree, confirm `npm ls
rescript-rewind` shows the package, then re-run both
`node scripts/place-check.mjs --skip-build --timeout 150` and
`node scripts/haul-smoke.mjs --skip-build` and tick C1/C2 once both are
green (commit `scripts/place-check.mjs` and `scripts/place-check.browser.js`
together with that, plus the four screenshots into
`docs/shots/haul-map/` and the three-sentence Testing-section note in the
repo CLAUDE.md, both still to do).

Environment fix, 2026-09-26: this worktree had no `rescript-rewind` in `node_modules`, so Node
found the main checkout's copy, and the bundle held two copies of React. `npm install` fixed it.
After that, `node scripts/haul-smoke.mjs --skip-build` passed.

Finished 2026-09-26, commit `2282342`. Added a sixth in-browser case, "outbox on a done haul":
abort the place POST, start a haul, wait for "Place not sent yet", tap Done, wait for the done
screen's email note (FIXTURES=1 always uses the outbox), remove the route, reload with no
further tap, and check the place line reads "Place saved" and `GET /api/hauls/:id` shows the
place. The reload restores the haul phase through `HaulStarted`, so the page shows the ordinary
scan card (not the `.haul-receipt` stamp) once reloaded — the place line still renders there and
updates correctly, so this is a naming nuance in the brief's "done screen" wording, not a script
or app failure.

`node scripts/place-check.mjs --skip-build --timeout 150`:

```
{"ok":true,"failures":[],"port":57821,"cases":{"saved":{"haulId":"59734b82-a908-4c08-8734-6d3623b14872","text":"Place saved · ±35 m · 0.0 s","place":{"lat":61.2181,"lon":-149.9003,"accuracyM":35,"source":"gps","at":"2026-09-26T16:31:18.793Z"},"outboxKeyLeft":false,"ok":true},"late":{"haulId":"311e4c78-1e63-444d-a161-13050fbfeb60","text":"Place saved · ±35 m · 0.0 s","ok":true},"outbox":{"haulId":"761b0425-c2c4-499e-b8ed-9c908cc72bf0","textBefore":"Place not sent yetTry again","outboxValue":"{\"lat\":61.2181,\"lon\":-149.9003,\"accuracyM\":35,\"source\":\"gps\"}","textAfter":"Place saved · ±35 m","placeAfter":{"lat":61.2181,"lon":-149.9003,"accuracyM":35,"source":"gps","at":"2026-09-26T16:31:21.614Z"},"outboxKeyLeftAfter":false,"ok":true},"denied":{"haulId":"4cbcfe9e-4b2c-486a-9396-448390899fcd","naturalDenialWorked":true,"text":"No place","usedOverride":false,"ok":true},"failed":{"haulId":"ad82d6df-32d7-4805-b93c-68a2fd78f3f1","textBefore":"No place yetTry again","textAfter":"Place saved · ±35 m · 0.0 s","ok":true},"outboxDone":{"haulId":"0b191277-86b8-4035-b30a-0be95895cc9e","textBefore":"Place not sent yetTry again","receiptText":"written to data/outbox/0b191277-86b8-4035-b30a-0be95895cc9e.eml because FIXTURES=1","textAfter":"Place saved · ±35 m","placeAfter":{"lat":61.2181,"lon":-149.9003,"accuracyM":35,"source":"gps","at":"2026-09-26T16:31:23.408Z"},"ok":true}},"privacy":{"lat":true,"lon":true},"ms":5534,"outDir":"/Users/dwight/code/reflip/.claude/worktrees/sharp-borg-0aed69/data/place-check/2026-09-26T16-31-17-962Z","serverLog":"/Users/dwight/code/reflip/.claude/worktrees/sharp-borg-0aed69/data/place-check/2026-09-26T16-31-17-962Z/server.log","shots":{"saved":"...","not-sent":"...","denied":"...","failed":"...","done-reload":"..."}}
```

`node scripts/haul-smoke.mjs --skip-build`:

```
{"ok":true,"failures":[],"n":5,"port":57999,"haulId":"aa9e7055-4798-46bb-8f63-bda2d557add4","counts":{"queued":0,"running":0,"valued":5,"failed":0},"emailNote":"written to data/outbox/aa9e7055-4798-46bb-8f63-bda2d557add4.eml because FIXTURES=1","gemCount":10,"cropsMissing":5,"cards":[{"index":0,"opened":true,"hasBox":true,"expectBox":true,"prevClosed":null,"closed":true},{"index":1,"opened":true,"hasBox":true,"expectBox":true,"prevClosed":true,"closed":true},{"index":2,"opened":true,"hasBox":true,"expectBox":true,"prevClosed":true,"closed":true},{"index":3,"opened":true,"hasBox":true,"expectBox":true,"prevClosed":true,"closed":true},{"index":4,"opened":true,"hasBox":true,"expectBox":true,"prevClosed":true,"closed":true},{"index":5,"opened":true,"hasBox":false,"expectBox":false,"prevClosed":true,"closed":true},{"index":6,"opened":true,"hasBox":false,"expectBox":false,"prevClosed":true,"closed":true},{"index":7,"opened":true,"hasBox":false,"expectBox":false,"prevClosed":true,"closed":true},{"index":8,"opened":true,"hasBox":false,"expectBox":false,"prevClosed":true,"closed":true},{"index":9,"opened":true,"hasBox":false,"expectBox":false,"prevClosed":true,"closed":true}],"soldLink":{"url":"https://www.ebay.com/sch/i.html?_nkw=vintage%20brass%20table%20lamp%20working&LH_Sold=1&LH_Complete=1","cardUnchanged":true},"idbDelete":"success","consoleErrors":[],"photoRoute":{"status":200,"contentType":"image/jpeg"},"ms":7299,"outDir":"/Users/dwight/code/reflip/.claude/worktrees/sharp-borg-0aed69/data/smoke/2026-09-26T16-32-01-735Z","shots":["...","...","...","..."]}
```

## Review fixes

A reviewer read the diff to `7d47a4d`. The brain half is sound. Do these, then run C1 and C2.

- [x] R1 (commit e769567). App.res mount effect: `restoreHaul` returns the restored haul id
      (`option<string>`), and `restorePlaces` gets that id directly. Removed the wrong
      comment — `rewind.live` in that closure is fixed to the first render's value
      (`React.useEffect0`'s closure runs once), so it never reflected the HaulStarted
      dispatch. `npm test`: 1001 ok, 0 not ok.
- [x] R2 (commit 271053c). `src/web/AppState.res` so far:
      `placeState`'s `PlaceSaved` is now `PlaceSaved(option<Types.place>, option<float>)` (was
      `option<placeFix>`); `msg`'s `PlaceSent` is now `PlaceSent(option<Types.place>)` (was
      `Types.place`); `fixOfPlaceState`'s `PlaceSaved` arm now returns `None` (a saved state no
      longer carries a full fix). Still to do, in order:
      1. `placeLine` (L242ish): rewrite so the "brain: None" branch's `PlaceSaved` case reads
         the new two-field payload and never returns "No place yet" for it. Plan: a local
         `placeSavedText = (p: Types.place, tookMs: option<float>): string` (switch on
         `p.source`, Pin -> "Place set by hand", Gps -> "Place saved · " ++ accuracy ++ took)
         used by both the `Some(p)` branch (brain has it) and `PlaceSaved(Some(p), tookMs)`;
         add a `PlaceSaved(None, tookMs)` arm giving `"Place saved" ++ took` (R5 will make Api
         return this shape on a 200 whose place doesn't decode — still counts as saved).
      2. `update`'s `PlaceSent(place)` case: build
         `PlaceSaved(place, fixOfPlaceState(model.place)->Option.flatMap(fix => fix.tookMs))`.
      3. `src/web/App.res` `sendPlace`'s `Sent(place) => ... dispatch(AppState.PlaceSent(Some(place)))`
         (wrap in `Some`; `Api.postPlace` itself is untouched until R5).
      4. `src/tests/AppStateTest.res` `runPlace`: every `AppState.PlaceSaved(Some(fix))` literal
         and the `AppState.PlaceSent({...})` call need the new shapes. Add the two cases the
         brief calls for: a `PlaceSent` dispatched from `PlaceAsking`/`PlaceFailed`/`PlaceNotAsked`
         gives `placeLine` text "Place saved · ±N m" (no took suffix, since `fixOfPlaceState`
         gives `None` from those states); a `PlaceSent` from `PlaceSending(fix-with-tookMs)`
         keeps the fix's `tookMs` and the text adds " · T s". Build the `Types.place` value used
         in `PlaceSent`'s payload with `accuracyM: Some(13.0)` etc., `source: Gps`.
      5. `npx rescript build`, fix fallout, `npm test`, then commit and tick this line.
      Do R4 (haul id on the same three msgs) as a separate step/commit after R2 is green — R4
      changes `PlaceSent`/`PlaceSendFailed`/`PlaceRejected`'s payload again (prepend `string`),
      touching the same `update` arms and the same `sendPlace` call site, so finish R2 first.
- [x] R3 (commits 6fab184, 8a8a68a). `ClaudeClient` gets `sendBody`/`callBody`, which take a body;
      the 400 retry removes the "output_config" key from that same body via a copied, typed
      `Dict`, no `Obj.magic`. `send`/`call` become thin wrappers over them via `buildRequestBody`,
      so the scan route is unchanged. `HaulWorker` gets `requestFor(t, scene)`, giving the model,
      the mode and the body; `requestBodyFor` maps it to the body, and `runScene` sends that same
      body through `callBody`. Test (in `ClaudeCutOffTest.res`, which already mixes a stub server
      with direct `buildRequestBody` checks): the body with structuredOutput true, minus
      "output_config", stringifies equal to the body with structuredOutput false; a stub server
      counts requests to confirm `callBody` retries once on a 400 naming output_config. `npm
      test`: 1013 ok, 0 not ok.
- [x] R4 (commit 37314a9). The send-result msgs (sent, send failed, rejected) carry the haul id.
      `update` ignores a msg whose haul id is not the current haul's.
- [x] R5 (commit 6a8f1c5). `Place.decodeInput` rejects a lat, lon or accuracyM that is not finite
      (`1e999`). `Api.postPlace`: a 200 whose place does not decode deletes the key and counts as
      saved.


## Step 3: GET /api/hauls and HaulList

Plan, per `docs/spec-haul-map.md` "Shape" and MVP step 3:

- [x] S1. `Types.res`: `haulBuy`, `haulListRow` types and `encodeHaulList`, next to `haulStatus`.
      `npx rescript build` compiles clean.
- [x] S2. `Shared.res`: `decodeHaulList`, field for field against the encoder.
      `npx rescript build` compiles clean.
- [x] S3. `Store.res`: `listHauls`, `photoCountsOf`, `findsAll` queries.
- [x] S4. `HaulList.res`: pure `build` and a thin `fromStore`.
- [x] S5. `Server.res`: `ListHauls` route, `GET /api/hauls` returns 200 with the array.
- [x] S6. `HaulListTest.res`, registered in `AllTests.res`. `npm test` ends with
      "all tests passed".

### Log

S1 and S2 went clean, no failed attempts. A TURN-COUNTER note arrived at
turn 60, right after S2's build check, before any S3 edit. A fresh agent
did S3 through S6 next, with no failed attempts. `npm test` ends with
"all tests passed", with 20 new checks in `HaulListTest.res`.

A review found three tests that could not fail. Commit `e51e269` fixes
them. Each fixed test fails when `HaulList.res` drops its sort or its
haul filter. On `e51e269`, `npm test` passed 1042 checks.
`scripts/haul-smoke.mjs` and `scripts/place-check.mjs` passed on the same
source. A live call on a fixture brain gave `photoCount` 2 and `gemCount`
4 for a haul with two photos. The server log had no coordinates.

### What S3-S6 built

- `Store.listHauls` reads every haul. It sorts by `startedAt`, then by
  `rowid`, both newest first.
- `Store.photoCountsOf` counts the scenes of each haul. It returns a
  dict from `haulId` to that count.
- `Store.findsAll` reads every find across every haul. Each find carries
  its `haulId`, oldest first.
- `HaulList.build` turns those rows into the reply shape. It sorts the
  hauls by `startedAt` itself, with a stable sort, so the SQL order
  still breaks a tie.
- `HaulList.build` counts a find as a gem when its high estimate is at
  or above the gem minimum.
- `HaulList.build` turns each paid find into a buy. A find with no paid
  amount is not a buy.
- `HaulList.fromStore` calls the three `Store` queries above and passes
  their result to `build`.
- `Server.handleListHauls` calls `HaulList.fromStore` and sends the
  result as JSON. It logs nothing about the rows.
- `GET /api/hauls` now parses to the new `ListHauls` route.

## Status on 2026-09-26

MVP step 1 is done. PR m0n01d/reflip#28 holds it. `npm test`, `scripts/haul-smoke.mjs` and `scripts/place-check.mjs` passed on `469d17e`.

MVP step 2, the phone test, waits for Dwight:

1. Stop any other brain on port 8787.
2. In this worktree, run `npm run build`, then `npm start`. `npm start` loads the live keys from `~/.config/reflip/env`.
3. On the iPhone, open https://dwights-macbook-pro.tail128d00.ts.net in Safari. `tailscale serve` already proxies it to 127.0.0.1:8787, on the tailnet only.
4. Start one haul indoors and one haul outdoors. For each, write down the "Place saved · ±N m · T s" line and whether iOS asked for the permission.
5. Add the page to the Home Screen. Do step 4 again from the Home Screen icon.
6. Write the results in `docs/spec-haul-map.md`, MVP step 2. If the results show a need, change the timeout (15 s now, in `App.askPlace`).

Step 3 (`GET /api/hauls` and `HaulList.res`) is done on branch `claude/haul-map-list`, stacked on PR m0n01d/reflip#28. See "Step 3" above. Step 4, the Map view, waits for the results in the spec.
