# reflip haul mode: snap fast, get the gems by email

Status: proposal, written 2026-09-24. Haul mode extends M0. It shares the `finds` table with M1 (`docs/spec-lite-m1.md`, on PR #2).

## Problem

In M0, the phone page sends one photo and waits for the reply. A real scene takes a median of 47 s in Claude (see "The numbers the first M1 experiment measured" in `CLAUDE.md`, PR #3). The next photo replaces the reply, and the brain saves no items.

At a thrift store or a yard sale, Dwight wants to walk the aisles and photograph shelves fast: books, electronics, shoes. He does not want to wait at each shelf. The brain values the photos in the background. When Dwight taps Done, the brain emails him a digest of the gems. Then he goes back and pulls the gems off the shelves.

A haul is the set of photos from one visit. A gem is an item that is worth enough to resell (see Gems).

## How it works

1. Start. Dwight opens the page and taps Start haul. He can type a store name.
2. Snap. Dwight adds photos in two ways. He takes a photo in the page, and the page is ready for the next photo at once. Or he takes many photos with the iOS Camera app, then picks them all at once in the page.
3. Queue. The page resizes each photo with `Resize.res` and keeps it on the phone. It uploads the photos in the background, one at a time. The brain answers each upload at once with a scene ID. It does not wait for Claude.
4. Value. The brain values the queued scenes in the background, a few at a time. The page shows four counts: on the phone, uploaded, valued, failed. It also shows the gems so far and the cost so far.
5. Done. Dwight taps Done. The page uploads the photos that are left, then tells the brain. When the queue of that haul is empty, the brain sends one email.
6. Collect. The email lists the gems, best first. Each gem has a thumbnail of its photo and a line that tells where the item is in the photo. It also has the range and a link to eBay sold listings. The same list stays in the page.

## Gems

- An item is a gem if its `estimateHighUsd` is $20 or more. `HAUL_GEM_MIN_USD` in `~/.config/reflip/env` changes the threshold.
- The digest sorts the gems by `estimateLowUsd`, highest first.
- The digest also gives the count of other items and the list of failed photos.
- The haul prompt asks Claude to list only the items that can resell for the threshold or more, and to count the others. A shelf of 40 books then gives a short list. In the first experiment, 19 items used 7,955 of the 8,192 output tokens that `max_tokens` allows.

## Shape

The phone page:

- A haul view: Start haul, Take photo, Add photos, the counts, the gems so far, and Done.
- Add photos is `<input type="file" multiple accept="image/*">` with no `capture` attribute, so iOS opens the photo library.
- The photo queue lives in IndexedDB, through `idb-keyval`. `WebApi.res` gets typed bindings for `get`, `set`, `del` and `keys`. Each entry holds the resized JPEG blob, the haul ID and a client ID from `crypto.randomUUID`.
- The page deletes an entry only after the brain answers 202 for it. If the page reloads, the queue starts again from IndexedDB.
- The page uploads one photo at a time. If an upload fails, the page waits 5 s, then 15 s, then 60 s, and tries again. It never drops a photo.
- The page stays TEA: new `msg` variants in `AppState.res`, effects in `App.res`.

The brain:

- Store: SQLite through `node:sqlite`, in `data/reflip.db`, as M1 decided. `src/bindings/` gets typed externals for the `DatabaseSync` calls that the store uses. Each row decode returns an option.
- Table `hauls`: `haulId`, `name`, `startedAt`, `doneAt`, `emailedAt`, `costUsd`.
- Table `scenes`: `sceneId`, `haulId`, `clientId`, `status` (queued, running, done, failed), `photoPath`, `error`, `costUsd`, `claudeMs`, `createdAt`.
- Table `finds`: the M1 table with the M1 column names. Haul mode writes one row for each item in the reply. It adds the columns `sceneId` and `where`. M1 adds the paid and sold entries later.
- Photos: `data/photos/<sceneId>.jpg`. `data/` is gitignored.
- The worker is a queue inside the brain process. It runs at most `HAUL_CONCURRENCY` Claude calls at a time, 4 by default. When the brain starts, it sets each `running` scene back to `queued`. A restart then loses no photo.
- If Claude returns a 429 or a 529, the worker waits and keeps the scene queued. It stops the haul after 3 failures in a row and records why.
- Budget: when the cost of a haul reaches `HAUL_MAX_USD`, $10 by default, the worker stops that haul. The page and the digest say so.
- eBay: no change. Hard rule 1 holds. If the eBay keys exist, each gem gets its eBay stats after the Claude call, as in M0.

The routes:

- `POST /api/hauls` starts a haul and returns its ID.
- `POST /api/hauls/:id/scenes` takes one JPEG and a client ID. It saves the photo, queues the scene and answers 202 with the scene ID. If the same client ID comes again, the route returns the same scene ID. A retried upload then costs nothing.
- `GET /api/hauls/:id` returns the counts, the cost so far and the gems so far.
- `POST /api/hauls/:id/done` closes the haul.
- `POST /api/scene` stays as it is, so the single-photo flow keeps working.

The haul prompt:

- It is a haul variant of the text in `SystemPrompt.res`. It adds the gem threshold.
- The schema gets two fields. `where` is a short phrase that locates the item in the photo, for example "top shelf, fourth spine from the left, red". `otherCount` is the number of items that are not gems.
- If `stop_reason` is `max_tokens`, the scene fails with the error "reply cut off". The digest lists that photo.

The digest and the email:

- `Digest.res` is a pure function from the rows of one haul to a subject, an HTML body and a text body. It has a hand-computed test.
- `Email.res` is a copy of dippa's `src/worker/Email.res`, with the two fixes that `flip-scout.md` in app-ideas names. It encodes UTF-8 correctly, and it decodes the token response with no `%identity` cast.
- The email goes through the Gmail API with an OAuth refresh token. The secrets are `GMAIL_CLIENT_ID`, `GMAIL_CLIENT_SECRET`, `GMAIL_REFRESH_TOKEN` and `EMAIL_TO`, in `~/.config/reflip/env`. Dwight writes them himself.
- Each gem thumbnail is an inline attachment (`cid:`), 480px on the long edge. Gmail cannot load images from the tailnet.
- With `FIXTURES=1`, the brain writes the email to `data/outbox/<haulId>.eml` and sends nothing. A missing Gmail secret outside fixture mode does the same, and the page tells why.

## Cost and time

The first experiment measured a median of $0.152 and 47.1 s in Claude for each scene.

- A haul of 60 photos costs about $9.
- With 4 calls at a time, the brain values about 5 photos a minute. The brain values photos while Dwight walks, so the digest comes a few minutes after Done.
- Four calls at a time read about 225,000 input tokens a minute. The rate-limit page lists 1,000 requests and 2,000,000 input tokens a minute for Claude Sonnet 5 (platform.claude.com/docs/en/api/rate-limits, read 2026-09-24). Cost, not the rate limit, sets the size of a haul.

## Decisions

- Keep SQLite on the brain, and keep a plain IndexedDB queue on the phone. Do not use PouchDB and CouchDB. Dwight asked about them on 2026-09-24.
- The reason: the phone makes one kind of data offline, photos that go one way to the brain. The brain makes all the values. A one-way queue needs no sync, no revisions and no conflict rules.
- CouchDB is one more service on the Mac mini, with its own admin login, port and backup. M1 adds no service.
- Checked on npm, 2026-09-24: PouchDB's last release is 9.0.0, from 2024-06-21. No ReScript bindings for PouchDB exist.
- Use `idb-keyval` for the queue, with our own bindings. Dwight asked about Dexie on 2026-09-24. Checked on npm the same day: `dexie` 4.4.6 had a release on 2026-09-10. The only ReScript binding, `@dusty-phillips/rescript-dexie` 0.4.0, is from 2023-03-05 and depends on Dexie 3. It fails the ReScript 12 gate, so both choices need our own bindings. `idb-keyval` 6.3.0 (2026-07-08) needs four.
- Do not share one database layer between the phone and the brain yet. Dwight asked about it on 2026-09-24. The phone keeps only a photo queue, and the brain keeps hauls, scenes and finds, so the two share no table. The types and the JSON decoders are the shared code, and `Shared.res` already holds them.
- If the phone must keep its own copy of the finds offline, use SQLite on both sides. `@sqlite.org/sqlite-wasm` 3.53.4 had a release on 2026-09-08 (npm). One ReScript module then holds the schema, the SQL and the row decoders. Each side gets a thin binding: `node:sqlite` on the brain, the WASM build on the phone. No ReScript SQLite bindings exist on npm. Before that step, find out how the WASM build keeps its data on iOS 27 Safari.
- Look at a sync database again if the phone must change data offline that the brain also changes. An example is a tick on each gem in a store with no signal. A small outbox of changes can do that too.
- Haul mode comes before the M1 paid and sold entry. It builds the store and the `finds` table that M1 then uses.

## MVP

In order:

1. The Claude timeout fix. It is a separate track, started 2026-09-24. Real scenes take up to 143 s, and the brain aborts at 60 s.
2. Store: the `node:sqlite` bindings and the three tables, with a test.
3. Brain queue: the haul routes, the worker, the restart recovery, the 429 wait and the budget stop. The tests use a stub Claude, not the network.
4. Haul prompt: the threshold, `where` and `otherCount`, and the cut-off check. `GuardTest.res` still passes.
5. Phone: the haul view, the IndexedDB queue, the retries, the counts and the gems so far.
6. Digest and email: `Digest.res` and its test, `Email.res`, and the outbox in fixture mode.
7. Smoke test in fixture mode. dev-browser at 390x844 starts a haul, adds 5 photos from `~/Pictures/reflip-m1/` in one pick, taps Done, and shows the gems. The `.eml` file in `data/outbox/` opens in Mail with its thumbnails.
8. One live haul of 3 photos to Dwight's own address. Ask Dwight before the first real email.

## Later

- The two-pass search, first in line after the MVP. Pass 1 names the items with no search. In the first experiment, a scene with no search cost about $0.03 and took 12 s to 18 s. Pass 2 searches only the possible gems. A haul multiplies the cost of each scene, so this matters more now.
- A lower effort on Sonnet 5, as the first experiment advises. The request field is `output_config.effort`, and the default on Sonnet 5 is `high` (platform.claude.com/docs/en/build-with-claude/effort, read 2026-09-24). Measure `medium` and `low` on a set of labeled photos first.
- The web search tool has no parameter that limits the result size of one search. Only `max_uses` limits the count (the web search tool page, read 2026-09-24).
- A cheap mode for a haul with no hurry: the Message Batches API. It costs 50% less, and most batches finish in less than 1 hour. It accepts the web search tool. The docs do not say whether it accepts `output_config.format` (the batch processing page, read 2026-09-24).
- A shutter in the page through `getUserMedia`, which is faster than the file picker. First make sure that iOS 27 does not ask for the camera again at each start.
- A thumbnail cropped to the gem. Claude gives no reliable boxes today.
- The haul as CSV through the share sheet, as `flip-scout.md` asks.
- Web Push when the digest is ready.
- Price tags read from the photo, so that the digest shows the profit.

## Non-goals

- Live video and the image-hash gate from `flip-scout.md`.
- A sync database. See Decisions.
- A second user, accounts or cloud hosting.

## Risks

- iOS runs the upload queue only while the page is open (`flip-scout.md`, from `04-native-vs-pwa.md`). If Dwight locks the phone, uploads stop until he opens the page again. IndexedDB keeps the photos until then.
- Book spines. The value of a book depends on its edition, and a photo of a shelf does not show the edition. Expect low confidence. A book gem is a lead to look at by hand.
- Cost on a big store. The budget stop and the cost in the page limit it.
- Rate limits. Too many calls at a time get 429 errors. The worker waits and keeps the scene queued.
- The host. The MacBook sleeps after 1 minute (`flip-scout.md`, checked 2026-09-24), and a sleeping brain values nothing. The Mac mini hosts the brain for a real haul.

## Open questions

- Is $20 on the high end the right gem threshold? Dwight sets it after the first real haul.
- Is $10 the right budget for one haul? At the median cost, it pays for about 65 photos.
