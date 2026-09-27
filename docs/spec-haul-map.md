# reflip haul map: where and when Dwight got things

Status: proposal, written 2026-09-25. It uses the buys of `docs/spec-budget.md`. It follows the map in ternpike (`src/elements/waypoint-map.js`), which uses Leaflet and OpenStreetMap (OSM) tiles.

## Problem

A haul records the photos and the finds of one visit, but not where the visit was. Dwight wants a simple map of the places and the dates of his hauls. The map shows which sales and stores paid off, and the date of each visit.

A place is the position of one haul: a latitude, a longitude and an accuracy in meters.

## How it works

1. Start. When Dwight taps Start haul, the page asks the phone for its position. The haul starts at once and does not wait for the position. When the position comes, the page sends it to the brain as the place of the haul.
2. Map. The Map view shows one pin for each haul that has a place. A haul with at least one buy gets a filled pin. A haul with no buy gets a hollow pin.
3. Look. When Dwight taps a pin, the panel under the map shows that haul. It shows the store name, the date and time, and the photo and gem counts. It also lists each buy with its paid price and its sale, and the total paid.
4. Fix. If a haul has no place or the wrong place, Dwight taps the haul in the list, then taps Set place. Then he taps the map where the haul was.

The list under the map shows the hauls newest first, with their dates. Range chips (30 days, 90 days, 1 year and All) limit the pins and the list. The default is 90 days.

## The position

- The page calls `navigator.geolocation.getCurrentPosition` with `enableHighAccuracy: true`, `timeout: 15000` and `maximumAge: 60000`. The default timeout is Infinity, so the page must set one (MDN, read 2026-09-25).
- The call works only in a secure context. [PR #4](https://github.com/m0n01d/reflip/pull/4) documents how the phone opens the brain over HTTPS through `tailscale serve`. Browsers also treat `http://127.0.0.1` as secure, so a smoke test on the Mac works too (MDN, Secure contexts, read 2026-09-25).
- A `Permissions-Policy` header can block the call. The brain sends no such header today.
- If Dwight denies the permission, the haul has no place. The haul view then shows "No place" and does not ask again.
- If the request times out or fails, the haul view shows "No place yet" and a Try again control.
- The page keeps the position in IndexedDB under the key `place|<haulId>` until the brain answers 200. The photo queue does the same with photos. After a reload, the page sends the position again.
- The IndexedDB value is JSON. The page decodes it at each read, as it does with all data from outside the program.
- If the position comes before the brain returns the haul ID, the page keeps the position until the ID comes.
- `WebApi.res` gets typed bindings for the call, the position and the error.

## The map

- Leaflet 1.9.4. It was the latest release on npm on 2026-09-25. Version 2.0 is at `2.0.0-alpha.1` and has a new API, so bind 1.9.4. The license is BSD-2-Clause.
- The tiles come from `https://tile.openstreetmap.org/{z}/{x}/{y}.png`, exactly. The OSM tile policy names this one URL, and says that other hostnames can be slower or go away without notice (read 2026-09-25). ternpike still uses the older `{s}.tile.openstreetmap.org` form.
- The attribution reads "© OpenStreetMap contributors", with a link to openstreetmap.org/copyright. It stays visible at the bottom right, as the policy requires. The attribution control of Leaflet does this.
- The page does not store tiles for offline use, and does not load tiles in advance. The policy forbids offline use of its servers.
- The browser sends the User-Agent and the Referer that the policy asks for. The page must not set a strict `Referrer-Policy`.
- The pins are circle markers (`L.circleMarker`). A circle marker is SVG, so it needs no icon image. A filled pin has a fill color. A hollow pin has only a ring. The selected pin is larger.
- The map has no clusters. A few dozen hauls a year do not crowd a map. `leaflet.markercluster` shows no change on npm since 2022-06-19.
- The map fits the pins in the range, with 40 px of padding. With one pin, the zoom is 15. If no haul has a place, the map shows the whole world, and Set place still works.
- A tap on a pin selects its haul. The panel under the map is a normal React view of the model, not a Leaflet popup. The store name then needs no HTML escape.
- The list under the map gives a screen reader a path to each haul. The pins do not.

The code:

- `src/web/Leaflet.res` gets typed externals for the calls that the map uses. The map calls are `map`, `setView`, `fitBounds`, `invalidateSize` and `remove`. The layer calls are `tileLayer`, `circleMarker`, `layerGroup`, `addTo`, `setStyle` and `clearLayers`. A click uses `on`. It uses no `%raw` and no `Obj.magic`. On 2026-09-25, `npm search rescript leaflet` found no ReScript bindings, only `react-leaflet` and plain Leaflet packages.
- The page loads `/app.css` from `public/`, and Vite copies that folder as it is. Load `leaflet/dist/leaflet.css` through Vite with no `%raw`, for example from a CSS file that `index.html` links to. Make sure that the tiles line up in the built `dist/` page, not only in `npm run dev:web`.
- `MapView.res` keeps the Leaflet map in a React ref. When the view opens, one effect makes the map. When the view closes, that effect removes the map. When the pins or the selection change, a second effect draws the pins again.
- The page stays TEA. A tap on a pin or on the map sends a `msg`. The model keeps the hauls, the range, the selected haul and the Set place mode.

## Shape

The brain:

- Table `hauls` gets five columns: `lat` (REAL), `lon` (REAL), `placeAccuracyM` (REAL), `placeSource` (TEXT, `gps` or `pin`) and `placeAt` (TEXT). `Store.openAt` adds them to an old database in place, as it does for `size`.
- `POST /api/hauls/:id/place` with `{"lat": 40.0, "lon": -100.0, "accuracyM": 35, "source": "gps"}` sets the place. The latitude must be from -90 to 90, and the longitude from -180 to 180. `accuracyM` is 0 or more, or null for a pin. A bad body gets a 400, and an unknown haul gets a 404.
- A `gps` place never replaces a `pin` place. A fix by hand wins over a late position from the phone. The brain then keeps the pin, and answers 200 with the stored place. The outbox keeps an entry until it gets a 200, so any other status makes the page send the position again after each reload.
- `GET /api/hauls` lists all hauls, newest first. Each row has `haulId`, `name`, `startedAt`, `place` (or null), `photoCount`, `gemCount`, `paidUsd` and `buys`. The page applies the range.
- `buys` lists each buy of the haul, with `name`, `paidUsd`, `paidOn`, `soldUsd` and `soldOn`. The panel shows this list, and a haul with at least one buy gets a filled pin.
- The buys of a haul are its paid finds, plus the manual buys with its `haulId` (see `docs/spec-budget.md`).
- `HaulList.res` builds each row from the store rows. It is a pure function with a test, `HaulListTest.res`.

The privacy rules:

- The place stays in `data/reflip.db` on the Mac.
- The place never goes into a Claude request. `GuardTest.res` gets a case. It sets a place with unusual values in a temp store. Then it gets the body from `HaulWorker.requestBodyFor` for a scene of that haul, and searches its JSON for the values.
- `ClaudeClient.buildRequestBody` reads nothing from the store today, so a case that only calls it cannot fail. If the budget spec has not added `HaulWorker.requestBodyFor` yet, add it with the place slice. It returns the exact body that the worker sends for one scene, and the worker builds its request through it.
- The place does not go into `data/scenes.jsonl`, the server log or the haul email.
- The tile requests go from the phone to the OSM tile servers, so OSM sees which area the map shows. The pins stay on the phone and the Mac.

The page:

- The view switch gets a Map entry, with `#map` in the URL hash. On 2026-09-25, main has no view switch. The UI/UX polish track builds it.
- The haul view gets the position request at Start haul, and the "No place" or "No place yet" line.
- The Map view has the range chips, the map, the list and the panel.

## Decisions

- One place for each haul. The haul spec defines a haul as the set of photos from one visit, so one place fits. A place for each photo is in Later.
- The position comes from the browser at Start haul, not from the photo. The page encodes each photo again on a canvas, and the new JPEG has no EXIF data.
- Use Leaflet and OSM raster tiles, as ternpike does. They need no API key and no account. Vector tiles, as MapLibre uses, are more than a map of pins needs.
- Show pins for hauls only. A scan, and a manual buy with no haul, have no place. See Later.
- Show a panel under the map, not a Leaflet popup. The panel is part of the TEA view, and it needs no HTML string.
- Keep Set place in the MVP. It fixes four cases: a denied permission, a poor position indoors, a haul from before this feature, and a haul started at home to pick photos from the library.
- The place slice and a map of hollow pins do not need the budget spec. The filled pins, the buy list in the panel and the Bought steps of the smoke test need budget MVP steps 2 to 4.

## MVP

The steps go in order. Steps 1 to 4 do not need the budget spec. Step 5 taps Bought, so it needs budget MVP steps 2 to 4.

1. Place: the `hauls` columns with the migration, `POST /api/hauls/:id/place`, the position request at Start haul, the IndexedDB outbox, and the `GuardTest.res` case.
2. Phone test of step 1, before the map is built. It settles the unknown iOS behavior first. On the iPhone, open the tailnet URL in Safari and from the Home Screen. Start a haul indoors and one outdoors. Record the accuracy, the time to a position, and whether iOS asks again at each start. Write the results in this spec. If they show a need, change the timeout.
   Result on 2026-09-26: Dwight reports that the position works on the iPhone. He recorded no accuracy or time values. The 15 s timeout stays.
3. `GET /api/hauls` and `HaulList.res`, with its test. Until budget MVP step 2 adds `manualBuys`, `buys` lists only the paid finds.
4. Map view: `Leaflet.res`, `MapView.res`, the pins, the range chips, the list, the panel and Set place.
5. Smoke test. Extend `scripts/haul-smoke.mjs`, which runs the brain in fixture mode with a throwaway `DATA_DIR`. Use dev-browser at 390x844 on `http://127.0.0.1`:
   - Grant the position permission with `context.grantPermissions`, and set a position with `context.setGeolocation`.
   - Start haul A and add `tests/fixtures/table.jpg`. Tap Done, and wait for the gem cards and the Start a new haul control. That control shows after the digest goes to the outbox.
   - Mark a gem Bought.
   - Open Map. Make sure that one filled pin shows at the set position, and that the panel lists the buy.
   - Clear the permission. Start haul B and add the photo. Make sure that the haul view shows that haul B has no place.
   - Select haul B in the list, tap Set place, and tap the map. Make sure that a hollow pin shows there.
   - Take a screenshot of each state. Make sure that the tiles and the attribution show.

   If dev-browser cannot set the permission, use Set place for both hauls. Step 2 then covers the position request.
6. One real haul with Dwight. Make sure that the pin lands on the correct store.

## Later

- A place for each photo, for a sale that covers many yards.
- A place for a scan, and for a manual buy with no haul.
- A place name from the coordinates (reverse geocoding) with Google, as ternpike does. ternpike's `server/geocode.js` calls the Google Geocoding API from its server, so the API key never reaches the browser. It caches each result and limits the rate.
  - The brain makes the call, with a new key in `~/.config/reflip/env`. It caches the name with the haul in `data/reflip.db`.
  - The Geocoding API takes `latlng=` and returns an address. The Places API (New) Nearby Search can return the name of the store. Before the build, read the price and the terms of both, and choose one.
  - This call sends the place to Google. Change the privacy rules in "Shape" in the same step.
- A pin color by age, or a time slider.
- Clusters for pins that crowd the map.
- If Leaflet slows the first paint of the scan view, load Leaflet only in the Map view.
- The pins of one month in the Budget view.
- A store identity. `flip-scout-teams.md` in app-ideas asks for one, and a place for each haul is a first step.

## Non-goals

- Directions or routes to a sale.
- Sales that other people post.
- Offline tiles. The OSM tile policy forbids them.
- A place anywhere but on the Mac and the phone.

## Risks

- A position indoors can be far off. In a large store, the pin can land across the street. Set place fixes it.
- iOS can ask for the permission again at each start of a Home Screen web app. MVP step 2 measures it.
- A haul started at home puts its pin on Dwight's home. Set place fixes it.
- The OSM tile servers can block heavy use. One user with a few map views a day is light use.
- Leaflet 2.0 changes the API. Stay on 1.9.4 until 2.0 is stable. Then update `Leaflet.res`.

## Open questions

- Keep the hollow pins for hauls with no buy, or show only hauls with buys? This spec keeps them.
- Is 90 days the right default range?
