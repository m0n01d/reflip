// reflip haul-view smoke script, the dev-browser sandbox half.
//
// scripts/haul-smoke.mjs prepends a line to this file that defines CONFIG:
//   { port, n, shotPrefix, b64Name, timeoutSec }
// before piping the two together to `dev-browser --browser reflip-smoke`.
//
// It drives the phone haul view end to end in fixture mode: start a haul,
// add the fixture photo n times in one pick, wait for it to be valued,
// check the scene-photo route, tap Done, then open, switch and close every
// gem card and tap one sold-listings link with the network stubbed.
//
// See ~/.claude/projects/-Users-dwight-code-reflip/memory/reflip-smoke-gotchas.md
// for the IndexedDB and deadline gotchas this script works around.

const DEADLINE = Date.now() + Math.max(10, CONFIG.timeoutSec - 20) * 1000;
const msLeft = () => Math.max(1000, DEADLINE - Date.now());

const consoleErrors = [];
const result = {
  ok: false,
  failures: [],
  haulId: null,
  counts: null,
  emailNote: null,
  gemCount: 0,
  cropsMissing: 0,
  cards: [],
  soldLink: null,
  idbDelete: null,
  consoleErrors,
  photoRoute: null,
  shots: [],
};
const failures = result.failures;

const page = await browser.newPage();
page.on("console", (msg) => {
  if (msg.type() === "error") consoleErrors.push({ type: "console", text: msg.text() });
});
page.on("pageerror", (err) => consoleErrors.push({ type: "pageerror", text: String(err) }));

async function readCounts() {
  const texts = await page.$$eval(".count", (els) => els.map((e) => e.textContent || ""));
  const get = (label) => {
    const t = texts.find((s) => s.startsWith(label));
    return t ? parseInt(t.slice(label.length).trim(), 10) : null;
  };
  return {
    onPhone: get("on phone"),
    uploaded: get("uploaded"),
    valued: get("valued"),
    failed: get("failed"),
  };
}

try {
  await page.setViewportSize({ width: 390, height: 844 });
  // Block ebay.com before any tap, so a stray tap on a sold link never
  // reaches the network. See the sold-link step for why this is abort().
  await page.context().route("**ebay.com**", (route) => route.abort());

  // A prior run against this named browser instance can leave a finished
  // haul in idb-keyval's "keyval-store" database, which auto-restores on
  // load and hides the "Start haul" button. Delete it from a same-origin
  // API page that does not run the app, so no open connection blocks it.
  await page.goto("http://127.0.0.1:" + CONFIG.port + "/api/hauls/none", {
    waitUntil: "domcontentloaded",
    timeout: msLeft(),
  });
  result.idbDelete = await page.evaluate(
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
  if (result.idbDelete !== "success") failures.push("the keyval-store delete answered " + result.idbDelete);
  consoleErrors.length = 0; // the API page's own 404 is expected, so count only app errors
  await page.goto("http://127.0.0.1:" + CONFIG.port + "/", { waitUntil: "domcontentloaded", timeout: msLeft() });
  await page.waitForSelector('button:has-text("Start haul")', { timeout: msLeft() });

  const [haulResp] = await Promise.all([
    page.waitForResponse((r) => r.url().includes("/api/hauls") && r.request().method() === "POST", {
      timeout: msLeft(),
    }),
    page.click('button:has-text("Start haul")'),
  ]);
  const haulJson = await haulResp.json();
  result.haulId = haulJson.haulId;
  if (!result.haulId) failures.push("no haulId in the POST /api/hauls response");

  const b64 = await readFile(CONFIG.b64Name);
  const buf = Buffer.from(b64, "base64");
  const files = [];
  for (let i = 1; i <= CONFIG.n; i++) {
    files.push({ name: "table" + i + ".jpg", mimeType: "image/jpeg", buffer: buf });
  }
  await page.locator('input[type="file"][multiple]').setInputFiles(files);

  let counts = await readCounts();
  while (Date.now() < DEADLINE && (counts.valued ?? 0) + (counts.failed ?? 0) !== CONFIG.n) {
    await page.waitForTimeout(1000);
    counts = await readCounts();
  }
  result.counts = counts;
  if ((counts.valued ?? 0) + (counts.failed ?? 0) !== CONFIG.n) {
    failures.push("valued+failed never reached n=" + CONFIG.n + ": " + JSON.stringify(counts));
  }

  const status = await page.evaluate(async (haulId) => {
    const r = await fetch("/api/hauls/" + haulId);
    return r.json();
  }, result.haulId);

  const firstSceneId = status.gems && status.gems.length > 0 ? status.gems[0].sceneId : null;
  if (firstSceneId) {
    result.photoRoute = await page.evaluate(async (sceneId) => {
      const r = await fetch("/api/scenes/" + sceneId + "/photo");
      return { status: r.status, contentType: r.headers.get("content-type") };
    }, firstSceneId);
    const ct = result.photoRoute.contentType || "";
    if (result.photoRoute.status !== 200 || !ct.includes("image/jpeg")) {
      failures.push(
        "GET /api/scenes/" + firstSceneId + "/photo did not give 200 image/jpeg: " + JSON.stringify(result.photoRoute)
      );
    }
  } else {
    failures.push("no gem had a sceneId before Done, so the photo route was not checked");
  }

  await page.click('button:has-text("Done")');

  let statusLine = "";
  while (Date.now() < DEADLINE) {
    statusLine = await page
      .$eval(".haul-view .status", (el) => el.textContent || "")
      .catch(() => "");
    if (statusLine && statusLine.toLowerCase().includes("outbox")) break;
    await page.waitForTimeout(1000);
  }
  result.emailNote = statusLine;
  if (!statusLine.toLowerCase().includes("outbox")) {
    failures.push('the status line never named the outbox: "' + statusLine + '"');
  }

  const gemCount = await page.$$eval(".haul-view ul.items > li.item", (els) => els.length);
  result.gemCount = gemCount;

  const cropInfo = await page.$$eval(".haul-view ul.items > li.item", (els) =>
    els.map((el) => {
      const crop = el.querySelector(".item-crop");
      return { missing: crop ? crop.classList.contains("item-crop-missing") : true };
    })
  );
  result.cropsMissing = cropInfo.filter((c) => c.missing).length;

  const items = page.locator(".haul-view ul.items > li.item");

  // Shot 1: every card closed, right after Done finishes.
  await page
    .locator(".haul-view .items")
    .scrollIntoViewIfNeeded({ timeout: msLeft() })
    .catch(() => {});
  result.shots.push(await saveScreenshot(await page.screenshot(), CONFIG.shotPrefix + "-closed.png"));

  const firstBoxIndex = cropInfo.findIndex((c) => !c.missing);
  const firstNoBoxIndex = cropInfo.findIndex((c) => c.missing);

  // Open every gem card in turn. AppState.res's ToggleGem keeps at most one
  // card open (src/web/AppState.res:262), so opening card i must close
  // whichever card was open before it.
  for (let i = 0; i < gemCount; i++) {
    await items.nth(i).click();
    const wrapSel = ".haul-view ul.items > li.item:nth-child(" + (i + 1) + ") .photo-wrap";
    let opened = true;
    try {
      await page.waitForSelector(wrapSel, { timeout: msLeft() });
    } catch (e) {
      opened = false;
      failures.push("card " + i + " did not show a .photo-wrap on tap");
    }
    const hasBox = opened ? await page.$eval(wrapSel, (el) => !!el.querySelector(".photo-box")) : null;
    const expectBox = !cropInfo[i].missing;
    if (opened && hasBox !== expectBox) {
      failures.push(
        "card " + i + " .photo-box presence was " + hasBox + ", expected " + expectBox + " from its crop"
      );
    }
    let prevClosed = null;
    if (i > 0) {
      const prevWrapSel = ".haul-view ul.items > li.item:nth-child(" + i + ") .photo-wrap";
      prevClosed = await page
        .waitForSelector(prevWrapSel, { state: "detached", timeout: Math.min(3000, msLeft()) })
        .then(() => true, () => false);
      if (!prevClosed) failures.push("card " + (i - 1) + " stayed open after card " + i + " was tapped");
    }
    if (i === firstBoxIndex) {
      await items
        .nth(i)
        .locator(".item-name, .item-top")
        .first()
        .scrollIntoViewIfNeeded({ timeout: msLeft() })
        .catch(() => {});
      result.shots.push(await saveScreenshot(await page.screenshot(), CONFIG.shotPrefix + "-open-box.png"));
    }
    if (i === firstNoBoxIndex) {
      await items
        .nth(i)
        .locator(".item-name, .item-top")
        .first()
        .scrollIntoViewIfNeeded({ timeout: msLeft() })
        .catch(() => {});
      result.shots.push(await saveScreenshot(await page.screenshot(), CONFIG.shotPrefix + "-open-nobox.png"));
    }
    result.cards.push({ index: i, opened, hasBox, expectBox, prevClosed, closed: null });
  }

  // Close pass: each card must close on a second tap. Tap the name, so the
  // tap never lands on the sold link inside an open card.
  for (let i = 0; i < gemCount; i++) {
    const wrapSel = ".haul-view ul.items > li.item:nth-child(" + (i + 1) + ") .photo-wrap";
    const name = items.nth(i).locator(".item-name").first();
    if ((await page.$(wrapSel)) === null) {
      await name.click({ timeout: msLeft() });
      await page.waitForSelector(wrapSel, { timeout: Math.min(3000, msLeft()) }).catch(() => {});
    }
    await name.click({ timeout: msLeft() });
    const closed = await page
      .waitForSelector(wrapSel, { state: "detached", timeout: Math.min(3000, msLeft()) })
      .then(() => true, () => false);
    result.cards[i].closed = closed;
    if (!closed) failures.push("card " + i + " did not close on a second tap");
  }

  // Sold link: ebay.com is blocked at the top of the script. Catch the popup, and
  // make sure the tap did not also toggle the card (GemCard's
  // stopPropagation on the link).
  //
  // Gotcha found while writing this script: route.fulfill() on the very
  // first navigation of a target=_blank popup silently stops Chromium's
  // "popup" event from ever firing on `page` (tested against this
  // dev-browser build), even though the exact same click fires it fine
  // with no route, or with route.continue(). route.abort() still blocks
  // the network the same way route.fulfill() would (Playwright intercepts
  // before the request leaves the process either way) and lets the event
  // fire, so this reads the link's own href for the URL instead of
  // popup.url() — an aborted popup's url() is "chrome-error://chromewebdata/".
  result.soldLink = { url: null, cardUnchanged: null };
  if (gemCount > 0) {
    const soldHref = await items.nth(0).locator("a.sold-link").getAttribute("href");
    if (!soldHref || !soldHref.includes("ebay.com")) {
      failures.push("card 0's sold link href did not point at ebay.com: " + soldHref);
    }
    await items.nth(0).click();
    await page
      .waitForSelector(".haul-view ul.items > li.item:nth-child(1) .photo-wrap", { timeout: msLeft() })
      .catch(() => {});
    const wasOpenBefore = (await page.$(".haul-view ul.items > li.item:nth-child(1) .photo-wrap")) !== null;
    try {
      const [popup] = await Promise.all([
        page.waitForEvent("popup", { timeout: msLeft() }),
        items.nth(0).locator("a.sold-link").click(),
      ]);
      await popup.waitForLoadState("domcontentloaded", { timeout: 5000 }).catch(() => {});
      result.soldLink.url = soldHref;
      await popup.close();
    } catch (e) {
      failures.push("the sold-link tap did not open a popup: " + String(e));
    }
    const isOpenAfter = (await page.$(".haul-view ul.items > li.item:nth-child(1) .photo-wrap")) !== null;
    result.soldLink.cardUnchanged = wasOpenBefore === isOpenAfter;
    if (wasOpenBefore !== isOpenAfter) {
      failures.push("tapping the sold link changed card 1's open state");
    }
    if (result.soldLink.url && !result.soldLink.url.includes("ebay.com")) {
      failures.push("the sold-link popup did not go to ebay.com: " + result.soldLink.url);
    }
    result.shots.push(await saveScreenshot(await page.screenshot(), CONFIG.shotPrefix + "-sold.png"));
  } else {
    failures.push("there were no gem cards, so the sold link was not tested");
  }

  if (consoleErrors.length > 0) failures.push(consoleErrors.length + " console error(s) on the page");
  result.ok = failures.length === 0;
} catch (e) {
  failures.push("uncaught: " + String(e && e.stack ? e.stack : e));
  result.ok = false;
} finally {
  try {
    await page.close();
  } catch (e) {}
  console.log("HAUL_SMOKE_RESULT " + JSON.stringify(result));
}
