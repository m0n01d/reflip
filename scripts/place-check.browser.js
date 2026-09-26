// reflip haul-map place-slice check, the dev-browser sandbox half.
//
// scripts/place-check.mjs prepends a line to this file that defines CONFIG:
//   { port, shotPrefix, timeoutSec }
// before piping the two together to `dev-browser --browser reflip-place`.
//
// Five cases, each on its own anonymous page so permission/geolocation
// state never leaks between them: a saved gps fix, a haul id that arrives
// late, the outbox surviving a reload, a denied prompt, and a failed
// prompt that a "Try again" tap then saves. A sixth case (privacy — the
// brain's own log must never carry a fixture coordinate) needs the
// server's log file, which this sandbox cannot read, so scripts/place-check.mjs
// checks that one itself after this script exits.
//
// See ~/.claude/projects/-Users-dwight-code-reflip/memory/reflip-smoke-gotchas.md
// for the IndexedDB gotchas this script works around (deleteDatabase blocked
// while the app page is open; delete it from a same-origin page with no app).

const DEADLINE = Date.now() + Math.max(10, CONFIG.timeoutSec - 20) * 1000;
const msLeft = () => Math.max(1000, DEADLINE - Date.now());
const BASE = "http://127.0.0.1:" + CONFIG.port;

const CASE1_LAT = 61.2181;
const CASE1_LON = -149.9003;
const CASE1_ACCURACY = 35;

const cases = { saved: {}, late: {}, outbox: {}, denied: {}, failed: {} };
const failures = [];
const result = { ok: false, failures, cases, shots: [] };

// -- helpers ----------------------------------------------------------------

async function resetState(page) {
  // A prior case can leave a finished (or in-progress) haul in idb-keyval's
  // "keyval-store" database, which auto-restores on load. Delete it from a
  // same-origin API page that does not run the app, so no open connection
  // blocks it (deleteDatabase answers "blocked" while the app page holds it
  // open).
  await page.goto(BASE + "/api/hauls/none", { waitUntil: "domcontentloaded", timeout: msLeft() });
  await page.evaluate(
    () =>
      new Promise((resolve) => {
        try {
          const req = indexedDB.deleteDatabase("keyval-store");
          req.onsuccess = () => resolve("success");
          req.onerror = () => resolve("error");
          req.onblocked = () => resolve("blocked");
        } catch (e) {
          resolve("error:" + String(e));
        }
      })
  );
  await page.evaluate(() => {
    try {
      localStorage.clear();
    } catch (e) {}
  });
}

async function gotoApp(page) {
  await page.goto(BASE + "/", { waitUntil: "domcontentloaded", timeout: msLeft() });
  // The scan page opens on its Scan tab. The haul-start form is on the Haul
  // tab (ScanShell.res), so switch tabs first.
  await page.getByRole("button", { name: "Haul", exact: true }).click({ timeout: msLeft() });
  await page.getByRole("button", { name: "Start a haul", exact: true }).waitFor({ timeout: msLeft() });
}

async function startHaulAndWait(page) {
  const startBtn = page.getByRole("button", { name: "Start a haul", exact: true });
  const [resp] = await Promise.all([
    page.waitForResponse((r) => r.url().endsWith("/api/hauls") && r.request().method() === "POST", {
      timeout: msLeft(),
    }),
    startBtn.click(),
  ]);
  const json = await resp.json();
  if (!json.haulId) throw new Error("no haulId in the POST /api/hauls response");
  return json.haulId;
}

async function placeLineText(page) {
  return page.$eval(".haul-place-line", (el) => el.textContent || "").catch(() => "");
}

async function waitForPlaceText(page, predicate, timeoutMs) {
  const deadline = Date.now() + Math.max(1000, timeoutMs);
  let text = "";
  while (Date.now() < deadline) {
    text = await placeLineText(page);
    if (predicate(text)) return text;
    await page.waitForTimeout(250);
  }
  return text;
}

async function fetchHaulStatus(page, haulId) {
  return page.evaluate(async (id) => {
    const r = await fetch("/api/hauls/" + id);
    return r.json();
  }, haulId);
}

async function idbGet(page, key) {
  return page.evaluate(
    (k) =>
      new Promise((resolve, reject) => {
        const req = indexedDB.open("keyval-store");
        req.onerror = () => reject(req.error);
        req.onsuccess = () => {
          const db = req.result;
          if (!db.objectStoreNames.contains("keyval")) {
            db.close();
            resolve(undefined);
            return;
          }
          const tx = db.transaction("keyval", "readonly");
          const store = tx.objectStore("keyval");
          const getReq = store.get(k);
          getReq.onsuccess = () => {
            const v = getReq.result;
            db.close();
            resolve(v);
          };
          getReq.onerror = () => {
            db.close();
            reject(getReq.error);
          };
        };
      }),
    key
  );
}

// -- case 1: saved ------------------------------------------------------------

async function caseSaved() {
  const page = await browser.newPage();
  try {
    await page.setViewportSize({ width: 390, height: 844 });
    await resetState(page);
    await page.context().grantPermissions(["geolocation"]);
    await page.context().setGeolocation({ latitude: CASE1_LAT, longitude: CASE1_LON, accuracy: CASE1_ACCURACY });
    await gotoApp(page);
    const haulId = await startHaulAndWait(page);
    cases.saved.haulId = haulId;

    const text = await waitForPlaceText(page, (t) => t.includes("Place saved · ±35 m"), msLeft());
    cases.saved.text = text;
    if (!text.includes("Place saved · ±35 m")) {
      failures.push("case saved: the place line never showed the gps fix, last text: " + JSON.stringify(text));
    }

    const status = await fetchHaulStatus(page, haulId);
    cases.saved.place = status.place;
    if (!status.place || Math.abs(status.place.lat - CASE1_LAT) > 0.0005 || status.place.source !== "gps") {
      failures.push("case saved: GET /api/hauls/:id place mismatch: " + JSON.stringify(status.place));
    }

    const outboxValue = await idbGet(page, "place|" + haulId);
    cases.saved.outboxKeyLeft = outboxValue !== undefined && outboxValue !== null;
    if (cases.saved.outboxKeyLeft) {
      failures.push("case saved: place|" + haulId + " was still in the outbox after a 200");
    }

    result.shots.push(await saveScreenshot(await page.screenshot(), CONFIG.shotPrefix + "-saved.png"));
    cases.saved.ok = failures.filter((f) => f.startsWith("case saved:")).length === 0;
  } catch (e) {
    failures.push("case saved: uncaught: " + String(e && e.stack ? e.stack : e));
  } finally {
    await page.close().catch(() => {});
  }
}

// -- case 2: late haul id -----------------------------------------------------

async function caseLate() {
  const page = await browser.newPage();
  try {
    await page.setViewportSize({ width: 390, height: 844 });
    await resetState(page);
    await page.context().grantPermissions(["geolocation"]);
    await page.context().setGeolocation({ latitude: CASE1_LAT, longitude: CASE1_LON, accuracy: CASE1_ACCURACY });
    await page.route("**/api/hauls", async (route) => {
      if (route.request().method() === "POST") {
        await new Promise((r) => setTimeout(r, 2000));
      }
      await route.continue();
    });
    await gotoApp(page);
    const haulId = await startHaulAndWait(page);
    cases.late.haulId = haulId;

    const text = await waitForPlaceText(page, (t) => t.includes("Place saved"), msLeft());
    cases.late.text = text;
    if (!text.includes("Place saved")) {
      failures.push(
        "case late: place was never saved once the delayed haul id arrived, last text: " + JSON.stringify(text)
      );
    }
    await page.unroute("**/api/hauls");
    cases.late.ok = failures.filter((f) => f.startsWith("case late:")).length === 0;
  } catch (e) {
    failures.push("case late: uncaught: " + String(e && e.stack ? e.stack : e));
  } finally {
    await page.close().catch(() => {});
  }
}

// -- case 3: outbox, then a reload --------------------------------------------

async function caseOutbox() {
  const page = await browser.newPage();
  try {
    await page.setViewportSize({ width: 390, height: 844 });
    await resetState(page);
    await page.context().grantPermissions(["geolocation"]);
    await page.context().setGeolocation({ latitude: CASE1_LAT, longitude: CASE1_LON, accuracy: CASE1_ACCURACY });
    await page.route("**/api/hauls/*/place", (route) => route.abort());
    await gotoApp(page);
    const haulId = await startHaulAndWait(page);
    cases.outbox.haulId = haulId;

    const text = await waitForPlaceText(page, (t) => t.includes("Place not sent yet"), msLeft());
    cases.outbox.textBefore = text;
    if (!text.includes("Place not sent yet")) {
      failures.push("case outbox: never showed 'Place not sent yet', last text: " + JSON.stringify(text));
    }
    const retryCount = await page.locator(".haul-place-retry").count();
    if (retryCount === 0) failures.push("case outbox: no Try again control while not sent");

    const outboxValue = await idbGet(page, "place|" + haulId);
    cases.outbox.outboxValue = outboxValue;
    if (outboxValue === undefined || outboxValue === null) {
      failures.push("case outbox: place|" + haulId + " was not in the outbox after the abort");
    }

    result.shots.push(await saveScreenshot(await page.screenshot(), CONFIG.shotPrefix + "-not-sent.png"));

    await page.unroute("**/api/hauls/*/place");
    await page.reload({ waitUntil: "domcontentloaded", timeout: msLeft() });

    const text2 = await waitForPlaceText(page, (t) => t.includes("Place saved"), msLeft());
    cases.outbox.textAfter = text2;
    if (!text2.includes("Place saved")) {
      failures.push(
        "case outbox: place was never saved after removing the route and reloading, last text: " +
          JSON.stringify(text2)
      );
    }

    const status = await fetchHaulStatus(page, haulId);
    cases.outbox.placeAfter = status.place;
    if (!status.place) failures.push("case outbox: GET /api/hauls/:id had no place after the resend");

    const outboxValue2 = await idbGet(page, "place|" + haulId);
    cases.outbox.outboxKeyLeftAfter = outboxValue2 !== undefined && outboxValue2 !== null;
    if (cases.outbox.outboxKeyLeftAfter) {
      failures.push("case outbox: place|" + haulId + " was still in the outbox after the resend");
    }
    cases.outbox.ok = failures.filter((f) => f.startsWith("case outbox:")).length === 0;
  } catch (e) {
    failures.push("case outbox: uncaught: " + String(e && e.stack ? e.stack : e));
  } finally {
    await page.close().catch(() => {});
  }
}

// -- case 4: denied ------------------------------------------------------------

async function caseDenied() {
  const page = await browser.newPage();
  try {
    await page.setViewportSize({ width: 390, height: 844 });
    await resetState(page);
    await page.context().clearPermissions();
    await gotoApp(page);
    const haulId = await startHaulAndWait(page);
    cases.denied.haulId = haulId;

    // Try the real Chromium denial path first: with no permission granted
    // and no UI to prompt, headless Chromium usually errors out with code 1
    // fast. Give it 5 s (per the brief) before falling back to a forced
    // override.
    const naturalDeadline = Date.now() + 5000;
    let text = "";
    let naturalWorked = false;
    while (Date.now() < naturalDeadline) {
      text = await placeLineText(page);
      if (text.includes("No place") && !text.includes("No place yet")) {
        naturalWorked = true;
        break;
      }
      await page.waitForTimeout(250);
    }
    cases.denied.naturalDenialWorked = naturalWorked;

    if (!naturalWorked) {
      // Fallback per the brief: force navigator.geolocation.getCurrentPosition
      // to call its error callback with {code: 1}, then start a fresh haul.
      // This dev-browser sandbox's `addInitScript` crashes the QuickJS
      // transport (probed 2026-09-26: "expected object, got undefined" on a
      // bare `page.addInitScript(() => {})`, independent of what the script
      // does), so the override is installed with a plain `page.evaluate`
      // instead, after the fresh navigation but before the click that
      // triggers the first (and only, for this fresh load) getCurrentPosition
      // call — that ordering is all `askPlace` needs, since it only reads
      // `navigator.geolocation` at click time, not at load time.
      await resetState(page);
      await gotoApp(page);
      await page.evaluate(() => {
        navigator.geolocation.getCurrentPosition = (_success, error) => {
          if (error) error({ code: 1, message: "denied (forced by place-check.browser.js)" });
        };
      });
      const haulId2 = await startHaulAndWait(page);
      cases.denied.haulId = haulId2;
      text = await waitForPlaceText(page, (t) => t.includes("No place") && !t.includes("No place yet"), msLeft());
    }
    cases.denied.text = text;
    cases.denied.usedOverride = !naturalWorked;
    if (!text.includes("No place") || text.includes("No place yet")) {
      failures.push("case denied: never showed the bare 'No place' line, last text: " + JSON.stringify(text));
    }
    const retryCount = await page.locator(".haul-place-retry").count();
    if (retryCount !== 0) failures.push("case denied: a Try again control was shown while denied");

    result.shots.push(await saveScreenshot(await page.screenshot(), CONFIG.shotPrefix + "-denied.png"));
    cases.denied.ok = failures.filter((f) => f.startsWith("case denied:")).length === 0;
  } catch (e) {
    failures.push("case denied: uncaught: " + String(e && e.stack ? e.stack : e));
  } finally {
    await page.close().catch(() => {});
  }
}

// -- case 5: failed, then Try again --------------------------------------------

async function caseFailed() {
  const page = await browser.newPage();
  try {
    await page.setViewportSize({ width: 390, height: 844 });
    await resetState(page);
    await page.context().grantPermissions(["geolocation"]);
    await page.context().setGeolocation({ latitude: CASE1_LAT, longitude: CASE1_LON, accuracy: CASE1_ACCURACY });
    await gotoApp(page);
    // This dev-browser sandbox's `addInitScript` crashes the QuickJS
    // transport (probed 2026-09-26), so the override goes in with a plain
    // `page.evaluate` after the navigation instead — installed before the
    // click below, which is the only thing that reads
    // `navigator.geolocation` on this fresh load.
    await page.evaluate(() => {
      window.__origGetPos = navigator.geolocation.getCurrentPosition.bind(navigator.geolocation);
      navigator.geolocation.getCurrentPosition = (_success, error) => {
        error({ code: 3, message: "unavailable (forced by place-check.browser.js)" });
      };
    });
    const haulId = await startHaulAndWait(page);
    cases.failed.haulId = haulId;

    const text = await waitForPlaceText(page, (t) => t.includes("No place yet"), msLeft());
    cases.failed.textBefore = text;
    if (!text.includes("No place yet")) {
      failures.push("case failed: never showed 'No place yet', last text: " + JSON.stringify(text));
    }
    const retryCountBefore = await page.locator(".haul-place-retry").count();
    if (retryCountBefore === 0) failures.push("case failed: no Try again control while failed");

    result.shots.push(await saveScreenshot(await page.screenshot(), CONFIG.shotPrefix + "-failed.png"));

    await page.evaluate(() => {
      navigator.geolocation.getCurrentPosition = window.__origGetPos;
    });
    await page.locator(".haul-place-retry").click({ timeout: msLeft() });

    const text2 = await waitForPlaceText(page, (t) => t.includes("Place saved"), msLeft());
    cases.failed.textAfter = text2;
    if (!text2.includes("Place saved")) {
      failures.push("case failed: Try again never saved the place, last text: " + JSON.stringify(text2));
    }
    cases.failed.ok = failures.filter((f) => f.startsWith("case failed:")).length === 0;
  } catch (e) {
    failures.push("case failed: uncaught: " + String(e && e.stack ? e.stack : e));
  } finally {
    await page.close().catch(() => {});
  }
}

// -- run all five, each isolated by its own try/catch above --------------------

await caseSaved();
await caseLate();
await caseOutbox();
await caseDenied();
await caseFailed();

result.ok = failures.length === 0;
console.log("PLACE_CHECK_RESULT " + JSON.stringify(result));
