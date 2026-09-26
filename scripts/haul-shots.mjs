#!/usr/bin/env node
// A repeatable screenshot rig for every Haul UI board named in
// docs/design/haul-ui/Main.dc.html (the design canvas), driven by
// dev-browser against the real FIXTURES=1 server.
//
//   node scripts/haul-shots.mjs [--out docs/shots/haul-ui] [--timeout 420]
//                                [--headed] [--keep-data]
//
// For each board it starts a fresh anonymous page, clears IndexedDB, mocks
// the haul JSON routes with data lifted from the canvas's GEMS/FAILS sample
// data (docs/design/haul-ui/Main.dc.html L369-400), drives the real controls
// (Start a haul, Add photos, Snap, a gem row, Done), and saves a 390-wide
// screenshot. It then builds one side-by-side compare-<Board>.png per board
// (canvas render on the left, this run's app screenshot on the right) with
// Python/Pillow, and writes docs/shots/haul-ui/click-path.md from the proof
// the browser script collected while driving each control.
//
// Modeled on scripts/haul-smoke.mjs (server bring-up, free port, throwaway
// DATA_DIR, dev-browser-instance-per-script). Does not touch that file or
// its sibling scripts/haul-smoke.browser.js.
//
// See HANDOFF-haul-shots.md in this worktree for the data model this script
// is built from (board -> JSON plan, verified against the canvas's own
// photo-arrival simulation).

import { spawn, spawnSync } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  rmSync,
  readFileSync,
  writeFileSync,
  existsSync,
  openSync,
  closeSync,
  copyFileSync,
} from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import net from "node:net";
import http from "node:http";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = process.cwd();

function argValue(name, def) {
  const i = process.argv.indexOf(name);
  return i === -1 ? def : process.argv[i + 1];
}
function hasFlag(name) {
  return process.argv.includes(name);
}

const HEADED = hasFlag("--headed");
const KEEP_DATA = hasFlag("--keep-data");
const TIMEOUT_SEC = parseInt(argValue("--timeout", "420"), 10);
const OUT_DIR = join(REPO_ROOT, argValue("--out", "docs/shots/haul-ui"));
const SCRATCH_ARG = argValue(
  "--scratch",
  join(
    tmpdir(),
    "reflip-haul-shots-" + Date.now()
  )
);
const SCRATCH_DIR = SCRATCH_ARG;

const JAIL = join(homedir(), ".dev-browser", "tmp");
const BROWSER_NAME = "reflip-shots";
const START = Date.now();
const runId = "haulshots-" + Date.now() + "-" + Math.random().toString(36).slice(2, 8);

mkdirSync(OUT_DIR, { recursive: true });
mkdirSync(SCRATCH_DIR, { recursive: true });

// -- canvas sample data (docs/design/haul-ui/Main.dc.html L366-400) --------

const PHOTO_W = 1568;
const PHOTO_H = 1176;
const EB6 = { n: 6, min: 28.5, med: 61.5, max: 89.99 };
const EB5 = { n: 5, min: 15, med: 22, max: 31 };

const GEMS = [
  { n: "Vintage clear glass bottles (pair)", b: [790, 90, 1000, 430], lo: 10, hi: 24, c: 0.3, p: 3, w: "back row, center, clear glass pair", size: "", q: "antique clear glass soda bottles lot", eb: null },
  { n: "Ceramic lit Christmas village church", b: [235, 170, 530, 520], lo: 15, hi: 32, c: 0.4, p: 5, w: "back left, the lit church", size: "", q: "vintage ceramic lighted christmas village church", eb: null },
  { n: "Blue and white transferware scalloped bowl set", b: [440, 505, 1000, 760], lo: 20, hi: 42, c: 0.4, p: 6, w: "front center, blue and white stack", size: "about 9 in wide", q: "vintage blue white transferware scalloped bowl plates", eb: EB6 },
  { n: "Pewter tankard/mug", b: [995, 610, 1095, 785], lo: 15, hi: 30, c: 0.3, p: 6, w: "front, right of the blue bowls", size: "", q: "vintage pewter tankard mug engraved", eb: EB5 },
  { n: "Ornate silver-plated round tray", b: [0, 540, 220, 650], lo: 15, hi: 28, c: 0.3, p: 8, w: "left edge, middle of the table", size: "", q: "vintage silver plated ornate round serving tray", eb: null },
  { n: "Gold-footed glass compote/hurricane vase", b: [1420, 0, 1568, 590], lo: 15, hi: 28, c: 0.35, p: 9, w: "far right, tall gold-footed glass", size: "about 12 in tall", q: "vintage gold footed glass compote vase", eb: null },
  { n: "Pink floral ceramic vase/planter", b: [1300, 320, 1470, 590], lo: 10, hi: 20, c: 0.3, p: 9, w: "right side, next to the tall glass", size: "", q: "vintage pink floral ceramic vase planter", eb: null },
  { n: "Vintage tin canister", b: [325, 445, 455, 635], lo: 10, hi: 25, c: 0.3, p: 20, w: "front left, below the church", size: "", q: "vintage advertising tin canister container", eb: null },
  { n: "Stacked scalloped-edge bowls", b: [0, 110, 215, 300], lo: 10, hi: 22, c: 0.35, p: 31, w: "back left corner", size: "", q: "vintage scalloped edge china bowls set", eb: null },
  { n: "Bisque figurine cluster (bride/groom & angels)", b: [480, 195, 710, 400], lo: 10, hi: 22, c: 0.3, p: 44, w: "back center, right of the church", size: "", q: "vintage bisque porcelain figurine set wedding angel", eb: null },
  { n: "Milk glass creamer pitcher with painted design", b: [980, 340, 1150, 495], lo: 10, hi: 20, c: 0.35, p: 58, w: "center right, by the milk glass", size: "", q: "vintage milk glass hand painted creamer pitcher", eb: null },
];

const round2 = (v) => Math.round(v * 100) / 100;

function gemJson(idx) {
  const g = GEMS[idx];
  const ebay = g.eb
    ? {
        count: g.eb.n,
        minUsd: g.eb.min,
        p25Usd: round2(g.eb.min + (g.eb.med - g.eb.min) * 0.5),
        medianUsd: g.eb.med,
        p75Usd: round2(g.eb.med + (g.eb.max - g.eb.med) * 0.5),
        maxUsd: g.eb.max,
      }
    : null;
  return {
    findId: "gem-" + idx,
    sceneId: "scene-p" + g.p,
    name: g.n,
    where: g.w || null,
    estimateLowUsd: g.lo,
    estimateHighUsd: g.hi,
    confidence: g.c,
    soldSearchUrl:
      "https://www.ebay.com/sch/i.html?_nkw=" + encodeURIComponent(g.q) + "&LH_Sold=1&LH_Complete=1",
    ebay,
    box: g.b,
    imageWidth: PHOTO_W,
    imageHeight: PHOTO_H,
    size: g.size || "",
  };
}

const isoMinAgo = (mins) => new Date(Date.now() - mins * 60000).toISOString();

function haulStatus({ haulId, valued, running, failed = 0, gemsIdx, cost, max = 10, other = 0, stopReason = null, failedList = [], startedMinAgo = 20 }) {
  return {
    haulId,
    name: "Birch St. estate sale",
    startedAt: isoMinAgo(startedMinAgo),
    doneAt: null,
    emailedAt: null,
    costUsd: cost,
    maxUsd: max,
    gemMinUsd: 20.0,
    stopReason,
    emailNote: null,
    counts: { queued: 0, running, valued, failed },
    gems: gemsIdx.map(gemJson),
    otherCount: other,
    failed: failedList,
  };
}

// -- board table (verified against the brief's numbers, see HANDOFF-haul-shots.md) --

const BOARDS = [
  { name: "Ready" },
  {
    name: "FirstSnaps",
    status: haulStatus({ haulId: "haul-firstsnaps", valued: 1, running: 1, gemsIdx: [], cost: 0.13, other: 0, startedMinAgo: 4 }),
    addPhotos: { mode: "snap", count: 1, outcome: "hang" },
  },
  {
    name: "GemsLanding",
    status: haulStatus({ haulId: "haul-gemslanding", valued: 8, running: 2, gemsIdx: [0, 1, 2, 3, 4], cost: 1.12, other: 11, startedMinAgo: 19 }),
    addPhotos: { mode: "multiple", count: 1, outcome: "hang" },
  },
  {
    name: "Gem",
    status: haulStatus({ haulId: "haul-gem", valued: 9, running: 2, gemsIdx: [0, 1, 2, 3, 4, 5, 6], cost: 1.28, other: 12, startedMinAgo: 20 }),
    openGemIdx: 2,
    checkSoldLink: true,
  },
  {
    name: "Finishing",
    status: haulStatus({ haulId: "haul-finishing", valued: 10, running: 1, gemsIdx: [0, 1, 2, 3, 4, 5, 6], cost: 1.41, other: 14, startedMinAgo: 21 }),
    addPhotos: { mode: "multiple", count: 2, outcome: "hang" },
    clickDone: { outcome: "hang" },
  },
  {
    name: "Done",
    status: haulStatus({ haulId: "haul-done", valued: 13, running: 0, gemsIdx: [0, 1, 2, 3, 4, 5, 6], cost: 1.82, other: 20, startedMinAgo: 25 }),
    clickDone: { outcome: "success" },
  },
  {
    name: "NoSignal",
    status: haulStatus({ haulId: "haul-nosignal", valued: 7, running: 3, gemsIdx: [0, 1, 2, 3], cost: 0.98, other: 11, startedMinAgo: 18 }),
    addPhotos: { mode: "multiple", count: 3, outcome: "fail" },
  },
  {
    name: "Failed",
    status: haulStatus({
      haulId: "haul-failed",
      valued: 11,
      running: 0,
      failed: 2,
      gemsIdx: [0, 1, 2, 3, 4, 5, 6],
      cost: 1.55,
      other: 14,
      startedMinAgo: 23,
      failedList: [
        { sceneId: "scene-fail-11", error: "Claude took longer than 180 s" },
        { sceneId: "scene-fail-12", error: "could not decode Claude’s reply" },
      ],
    }),
    clickDone: { outcome: "fail-retry" },
  },
  {
    name: "Stopped",
    status: haulStatus({
      haulId: "haul-stopped",
      valued: 72,
      running: 0,
      gemsIdx: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
      cost: 10.02,
      max: 10.0,
      other: 144,
      startedMinAgo: 90,
      stopReason: "budget reached: $10.02 of $10.00",
    }),
  },
];

// EbayBlock reuses the Gem board's data: one gem with stats (idx 2, the
// transferware bowl set, EB6) and one without (idx 0, clear glass bottles).
const EBAY_BLOCK_STATUS = BOARDS.find((b) => b.name === "Gem").status;

// -- free port / wait ---------------------------------------------------

function findFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, "127.0.0.1", () => {
      const p = srv.address().port;
      srv.close(() => resolve(p));
    });
    srv.on("error", reject);
  });
}

function waitForServer(p, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    function attempt() {
      const sock = net.connect({ port: p, host: "127.0.0.1" }, () => {
        sock.end();
        resolve();
      });
      sock.on("error", () => {
        sock.destroy();
        if (Date.now() > deadline) reject(new Error("server did not answer on port " + p + " in time"));
        else setTimeout(attempt, 200);
      });
    }
    attempt();
  });
}

// -- mock proxy -------------------------------------------------------------
// dev-browser's bundled Playwright build throws `TypeError: not a function`
// inside `route.fulfill()` for any request the real app's own code triggers
// (confirmed: the same failure happens with `contentType` and with `headers`,
// at the same internal frame `_innerFulfill`; `route.continue()`/`abort()`
// still work fine, matching the gotcha already noted in
// haul-smoke.browser.js, which avoids `fulfill()` for the same reason). So
// the haul JSON is mocked here, at a plain Node HTTP proxy the browser talks
// to directly, instead of via Playwright route interception.
function startProxy(publicPort, backendPort, photoBuf) {
  const boardsByName = new Map(BOARDS.map((b) => [b.name, b]));
  let currentBoardName = null;
  const doneCallTimestamps = [];

  function sendJson(res, status, obj) {
    const body = JSON.stringify(obj);
    res.writeHead(status, { "content-type": "application/json", "content-length": Buffer.byteLength(body) });
    res.end(body);
  }

  function readBody(req) {
    return new Promise((resolve) => {
      const chunks = [];
      req.on("data", (c) => chunks.push(c));
      req.on("end", () => resolve(Buffer.concat(chunks)));
    });
  }

  function proxyThrough(req, res) {
    const upstream = http.request(
      {
        host: "127.0.0.1",
        port: backendPort,
        path: req.url,
        method: req.method,
        headers: { ...req.headers, host: "127.0.0.1:" + backendPort },
      },
      (upRes) => {
        res.writeHead(upRes.statusCode, upRes.headers);
        upRes.pipe(res);
      }
    );
    upstream.on("error", (e) => {
      if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain" });
      res.end("haul-shots proxy error: " + String(e));
    });
    req.pipe(upstream);
  }

  const server = http.createServer(async (req, res) => {
    const url = req.url || "";
    const method = req.method || "GET";

    if (url === "/__test__/set-board" && method === "POST") {
      const body = await readBody(req);
      try {
        currentBoardName = JSON.parse(body.toString("utf8") || "{}").name || null;
      } catch (e) {}
      res.writeHead(204);
      res.end();
      return;
    }

    if (url === "/api/hauls/none") {
      res.writeHead(404, { "content-type": "text/plain" });
      res.end("not found");
      return;
    }

    if (url === "/api/hauls" && method === "POST") {
      await readBody(req);
      const board = boardsByName.get(currentBoardName);
      if (!board || !board.status) {
        sendJson(res, 500, { error: "haul-shots proxy: no board set for POST /api/hauls" });
        return;
      }
      sendJson(res, 200, board.status);
      return;
    }

    if (/^\/api\/hauls\/[^/]+$/.test(url) && method === "GET") {
      const board = boardsByName.get(currentBoardName);
      if (!board || !board.status) {
        sendJson(res, 404, { error: "no haul" });
        return;
      }
      sendJson(res, 200, board.status);
      return;
    }

    if (/^\/api\/hauls\/[^/]+\/scenes$/.test(url) && method === "POST") {
      await readBody(req);
      const board = boardsByName.get(currentBoardName);
      const outcome = (board && board.addPhotos && board.addPhotos.outcome) || "hang";
      if (outcome === "fail") {
        setTimeout(() => sendJson(res, 500, { error: "could not reach the server" }), 400);
      }
      // else: hang forever on purpose. The item stays "on phone".
      return;
    }

    if (/^\/api\/hauls\/[^/]+\/done$/.test(url) && method === "POST") {
      await readBody(req);
      doneCallTimestamps.push(Date.now());
      const board = boardsByName.get(currentBoardName);
      const outcome = (board && board.clickDone && board.clickDone.outcome) || "hang";
      if (outcome === "success") {
        const done = Object.assign({}, board.status, {
          doneAt: new Date().toISOString(),
          emailedAt: new Date().toISOString(),
        });
        sendJson(res, 200, done);
      } else if (outcome === "fail-retry") {
        sendJson(res, 500, { error: "could not reach the server" });
      }
      // else: hang forever on purpose. The Finishing bar stays on "sending".
      return;
    }

    if (/^\/api\/scenes\/[^/]+\/photo$/.test(url) && method === "GET") {
      res.writeHead(200, { "content-type": "image/jpeg", "content-length": photoBuf.length });
      res.end(photoBuf);
      return;
    }

    proxyThrough(req, res);
  });

  return new Promise((resolve, reject) => {
    server.on("error", reject);
    server.listen(publicPort, "127.0.0.1", () => resolve({ server, doneCallTimestamps }));
  });
}

// -- cleanup --------------------------------------------------------------

let serverProc = null;
let dataDir = null;
let port = null;
let proxyServer = null;
let cleaned = false;
const b64Names = { photo: runId + "-photo.jpg.b64", tiny: runId + "-tiny.jpg.b64" };

function elog(...a) {
  console.error(...a);
}

async function cleanup() {
  if (cleaned) return;
  cleaned = true;
  if (serverProc && !serverProc.killed) {
    try {
      serverProc.kill("SIGTERM");
    } catch (e) {}
  }
  if (proxyServer) {
    try {
      proxyServer.close();
    } catch (e) {}
  }
  for (const name of Object.values(b64Names)) {
    const p = join(JAIL, name);
    if (existsSync(p)) {
      try {
        rmSync(p);
      } catch (e) {}
    }
  }
  if (dataDir && !KEEP_DATA && existsSync(dataDir)) {
    try {
      rmSync(dataDir, { recursive: true, force: true });
    } catch (e) {}
  }
}

for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, async () => {
    elog("\nhaul-shots: " + sig + ", cleaning up…");
    await cleanup();
    process.exit(130);
  });
}

// -- the dev-browser sandbox script ---------------------------------------
// CONFIG is prepended by main() below, as "const CONFIG = {...};". Every
// per-board number lives in CONFIG.boards; this script only knows how to
// drive the controls generically. Deliberately written with no backticks
// and no template-literal interpolation, since it is embedded inside one.

const BROWSER_SCRIPT = `
const failures = [];
const proof = {};
const tinyBuf = Buffer.from(await readFile(CONFIG.tinyB64Name), "base64");

function boardById(haulId) {
  for (const b of CONFIG.boards) {
    if (b.status && b.status.haulId === haulId) return b;
  }
  return null;
}

async function freshPage() {
  const page = await browser.newPage();
  page.on("console", (msg) => {
    if (msg.type() === "error") {
      const text = msg.text();
      // Every 404/500 the browser can see here is one this script's own mock
      // proxy sent on purpose: the /api/hauls/none IDB-clear trick (404,
      // every board), and the NoSignal/Failed boards' deliberately failing
      // scenes/done calls (500, see BOARDS above). A genuine app bug would
      // show up as a pageerror or a different console message, not this one.
      if (/^Failed to load resource: the server responded with a status of (404|500)/.test(text)) return;
      failures.push("console error: " + text);
    }
    if (msg.type() === "log" && msg.text().indexOf("DBG ") === 0) console.log(msg.text());
  });
  page.on("pageerror", (err) => failures.push("pageerror: " + String(err)));
  page.on("request", (r) => {
    if (r.url().indexOf("/api/hauls") !== -1) console.log("DBG REQ " + r.method() + " " + r.url());
  });
  page.on("requestfailed", (r) => {
    if (r.url().indexOf("/api/hauls") !== -1) console.log("DBG REQFAIL " + r.method() + " " + r.url() + " " + (r.failure() && r.failure().errorText));
  });
  page.on("response", (r) => {
    if (r.url().indexOf("/api/hauls") !== -1) console.log("DBG RES " + r.status() + " " + r.url());
  });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.route("**ebay.com**", (route) => route.abort());
  // Clear any haul idb-keyval left by a previous run of this named browser,
  // same trick as haul-smoke.browser.js: visit a same-origin API page first
  // so the SPA never mounts and races the clear with restoreHaul().
  await page.goto("http://127.0.0.1:" + CONFIG.port + "/api/hauls/none", {
    waitUntil: "domcontentloaded",
    timeout: 15000,
  });
  await page.evaluate(
    () =>
      new Promise((resolve) => {
        try {
          const req = indexedDB.deleteDatabase("keyval-store");
          req.onsuccess = () => resolve(null);
          req.onerror = () => resolve(null);
          req.onblocked = () => resolve(null);
        } catch (e) {
          resolve(null);
        }
      })
  );
  await page.evaluate(() => {
    try {
      localStorage.clear();
    } catch (e) {}
  });
  return page;
}

async function setBoard(page, name) {
  // The haul JSON is mocked by the outer script's own HTTP proxy (see
  // startProxy() in haul-shots.mjs), not by page.route: this dev-browser
  // build's route.fulfill() throws "TypeError: not a function" for a
  // request the app itself triggers (confirmed at the _innerFulfill frame,
  // independent of contentType vs headers). This just tells the proxy which
  // board's canned data to serve next. A plain evaluate-triggered fetch
  // works fine here because no page.route matches this same-origin path.
  await page.evaluate(
    (n) => fetch("/__test__/set-board", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ name: n }) }),
    name
  );
}

async function goToHaulTab(page) {
  await page.goto("http://127.0.0.1:" + CONFIG.port + "/", { waitUntil: "domcontentloaded", timeout: 15000 });
  await page.getByRole("button", { name: "Haul", exact: true }).click({ timeout: 10000 });
}

async function startHaul(page) {
  const startBtn = page.getByRole("button", { name: "Start a haul", exact: true });
  await startBtn.waitFor({ timeout: 10000 });
  await Promise.all([
    page.waitForResponse((r) => r.url().includes("/api/hauls") && r.request().method() === "POST", { timeout: 10000 }),
    startBtn.click(),
  ]);
  await page.locator(".haul-tally").waitFor({ timeout: 10000 });
  proof.startHaul = true;
}

async function addPhotos(page, cfg) {
  const files = [];
  for (let i = 0; i < cfg.count; i++) {
    files.push({ name: "p" + i + ".jpg", mimeType: "image/jpeg", buffer: tinyBuf });
  }
  if (cfg.mode === "snap") {
    await page.locator('label[aria-label="Snap a photo"] input[type="file"]').setInputFiles(files[0]);
    proof.snap = true;
  } else {
    await page.locator('input[type="file"][multiple]').setInputFiles(files);
    proof.addPhotos = { count: cfg.count };
  }
  // No response ever arrives for a hung/failing scene POST, so just give the
  // resize + dispatch + (for "fail") the mocked round trip time to settle.
  await page.waitForTimeout(cfg.outcome === "fail" ? 2500 : 2000);
}

async function openGem(page, idx, label) {
  const row = page.locator(".haul-gem-row", { hasText: label });
  await row.click({ timeout: 10000 });
  await page.locator(".haul-gem-detail").first().waitFor({ state: "attached", timeout: 10000 });
}

async function closeGem(page, label) {
  const row = page.locator(".haul-gem-row", { hasText: label });
  await row.click({ timeout: 10000 });
}

async function checkSoldLink(page, label) {
  const item = page.locator(".haul-gem-item", { hasText: label });
  const soldLink = item.locator("a.scan-ebay-sold-btn");
  const href = await soldLink.getAttribute("href").catch(() => null);
  proof.soldLink = { href };
  if (!href || !href.includes("ebay.com")) {
    failures.push("sold link href did not point at ebay.com: " + href);
    return;
  }
  try {
    const [popup] = await Promise.all([page.waitForEvent("popup", { timeout: 5000 }), soldLink.click()]);
    await popup.waitForLoadState("domcontentloaded", { timeout: 3000 }).catch(() => {});
    await popup.close();
    proof.soldLinkPopupBlocked = true;
  } catch (e) {
    failures.push("sold link tap did not open a popup: " + String(e));
  }
}

async function shoot(page, name) {
  const buf = await page.screenshot({ fullPage: true });
  const path = await saveScreenshot(buf, CONFIG.shotPrefix + "-" + name + ".png");
  return path;
}

const shots = [];

for (const board of CONFIG.boards) {
  const page = await freshPage();
  try {
    if (board.name === "Ready") {
      await goToHaulTab(page);
      await page.locator(".haul-ready-start").waitFor({ timeout: 10000 });
      shots.push({ board: board.name, path: await shoot(page, board.name) });
      proof.readyScreen = true;
      await page.close();
      continue;
    }

    await setBoard(page, board.name);
    await goToHaulTab(page);
    await startHaul(page);

    if (board.addPhotos) {
      await addPhotos(page, board.addPhotos);
      if (board.addPhotos.outcome === "fail") {
        await page.locator(".haul-offline").waitFor({ timeout: 8000 }).catch((e) => {
          failures.push("board " + board.name + ": .haul-offline never appeared: " + String(e));
        });
        proof.uploadsFailing = true;
      }
    }

    if (typeof board.openGemIdx === "number") {
      const label = GEMS_NAMES[board.openGemIdx];
      await openGem(page, board.openGemIdx, label);
      proof.gemOpen = { label };
      if (board.checkSoldLink) await checkSoldLink(page, label);
    }

    if (board.clickDone) {
      const doneBtn = page.getByRole("button", { name: "Done", exact: true });
      await doneBtn.click({ timeout: 10000 });
      proof.doneTapped = true;
      if (board.clickDone.outcome === "success") {
        await page.locator("section[aria-label='Haul receipt']").waitFor({ timeout: 10000 });
        proof.receiptShown = true;
      } else if (board.clickDone.outcome === "fail-retry") {
        await page.locator(".haul-bar-fail").waitFor({ timeout: 10000 });
        // Wait past the 5s first-retry backoff (AppState.retryDelayMs(1))
        // so a second POST /done shows up in proof.doneCalls.
        await page.waitForTimeout(6500);
      } else {
        await page.locator(".haul-bar").waitFor({ timeout: 10000 });
      }
    }

    shots.push({ board: board.name, path: await shoot(page, board.name) });

    if (board.name === "Done") {
      const newHaulBtn = page.getByRole("button", { name: "Start a new haul", exact: true });
      await newHaulBtn.click({ timeout: 10000 });
      await page.locator(".haul-ready-start").waitFor({ timeout: 10000 });
      proof.newHaul = true;
      shots.push({ board: "Done-after-new-haul", path: await shoot(page, "Done-after-new-haul") });
    }

    if (board.name === "Gem") {
      // Prove a second gem switches the open one, then the same gem closes.
      const nextLabel = GEMS_NAMES[3]; // Pewter tankard/mug, the next row
      await openGem(page, 3, nextLabel);
      const stillOpenCount = await page.locator(".haul-gem-detail").count();
      proof.gemSwitch = { detailCount: stillOpenCount };
      await closeGem(page, nextLabel);
      const afterClose = await page.locator(".haul-gem-detail").count();
      proof.gemClose = { detailCount: afterClose };
    }
  } catch (e) {
    failures.push("board " + board.name + ": uncaught: " + String(e && e.stack ? e.stack : e));
  } finally {
    await page.close().catch(() => {});
  }
}

// -- EbayBlock: two element crops, reusing the Gem board's data ------------
try {
  const page = await freshPage();
  await setBoard(page, "Gem");
  await goToHaulTab(page);
  await startHaul(page);
  await openGem(page, 2, GEMS_NAMES[2]);
  const withStats = page.locator(".haul-gem-item", { hasText: GEMS_NAMES[2] }).locator(".scan-ebay");
  await withStats.waitFor({ timeout: 10000 });
  shots.push({ board: "EbayBlock-with", path: await saveScreenshot(await withStats.screenshot(), CONFIG.shotPrefix + "-EbayBlock-with.png") });
  await closeGem(page, GEMS_NAMES[2]);
  await openGem(page, 0, GEMS_NAMES[0]);
  const withoutStats = page.locator(".haul-gem-item", { hasText: GEMS_NAMES[0] }).locator(".scan-ebay");
  await withoutStats.waitFor({ timeout: 10000 });
  shots.push({ board: "EbayBlock-without", path: await saveScreenshot(await withoutStats.screenshot(), CONFIG.shotPrefix + "-EbayBlock-without.png") });
  await page.close();
} catch (e) {
  failures.push("EbayBlock: uncaught: " + String(e && e.stack ? e.stack : e));
}

console.log("HAUL_SHOTS_RESULT " + JSON.stringify({ failures, proof, shots }));
`;

// -- main -------------------------------------------------------------------

async function main() {
  const failures = [];

  port = await findFreePort();
  dataDir = mkdtempSync(join(tmpdir(), "reflip-shots-"));
  elog("haul-shots: port " + port + ", DATA_DIR " + dataDir);

  const childEnv = { ...process.env };
  for (const key of Object.keys(childEnv)) {
    if (key.startsWith("EBAY_")) delete childEnv[key];
  }
  delete childEnv.ANTHROPIC_API_KEY;
  delete childEnv.GMAIL_USER;
  delete childEnv.GMAIL_APP_PASSWORD;
  delete childEnv.EMAIL_TO;
  childEnv.FIXTURES = "1";
  childEnv.PORT = String(port);
  childEnv.DATA_DIR = dataDir;

  const serverLogPath = join(SCRATCH_DIR, "server.log");
  const serverLogFd = openSync(serverLogPath, "a");
  serverProc = spawn("node", ["src/Main.res.mjs"], {
    cwd: REPO_ROOT,
    env: childEnv,
    stdio: ["ignore", serverLogFd, serverLogFd],
  });
  serverProc.on("exit", (code, signal) => {
    if (!cleaned) elog("haul-shots: server exited early, code=" + code + " signal=" + signal);
  });

  try {
    await waitForServer(port, 20_000);
  } catch (e) {
    closeSync(serverLogFd);
    failures.push(String(e));
    return { ok: false, failures };
  }
  closeSync(serverLogFd);

  mkdirSync(JAIL, { recursive: true });
  const photoPath = argValue(
    "--photo",
    "/private/tmp/claude-501/-Users-dwight-code-reflip--claude-worktrees-priceless-williams-a1b440/f7d53f8d-6f57-4539-9be8-a416686f6022/scratchpad/artifact-files/640d86d1-22d6-4602-aa04-ae42248da940/be38a67f4b37d98c862a8a275b4e27c0.jpg"
  );
  const photoBuf = readFileSync(photoPath);
  writeFileSync(join(JAIL, b64Names.photo), photoBuf.toString("base64"));
  const tinyBuf = readFileSync(join(REPO_ROOT, "tests/fixtures/table.jpg"));
  writeFileSync(join(JAIL, b64Names.tiny), tinyBuf.toString("base64"));

  const publicPort = await findFreePort();
  const { server, doneCallTimestamps } = await startProxy(publicPort, port, photoBuf);
  proxyServer = server;
  elog("haul-shots: proxy on " + publicPort + " -> backend " + port);

  const gemsNamesLine = "const GEMS_NAMES = " + JSON.stringify(GEMS.map((g) => g.n)) + ";\n";
  const config = {
    port: publicPort,
    boards: BOARDS,
    shotPrefix: runId,
    tinyB64Name: b64Names.tiny,
  };
  const script = "const CONFIG = " + JSON.stringify(config) + ";\n" + gemsNamesLine + BROWSER_SCRIPT;

  const devBrowserArgs = ["--browser", BROWSER_NAME, "--timeout", String(TIMEOUT_SEC)];
  if (!HEADED) devBrowserArgs.push("--headless");

  elog("haul-shots: dev-browser " + devBrowserArgs.join(" "));
  // Async spawn, not spawnSync: the mock proxy above runs in this same
  // process, and spawnSync would block this process's event loop for the
  // whole run, so the proxy could never answer a request.
  const run = await new Promise((resolve) => {
    const child = spawn("dev-browser", devBrowserArgs, { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try {
        child.kill("SIGKILL");
      } catch (e) {}
      resolve({ status: null, stdout, stderr, error: new Error("dev-browser timed out after " + (TIMEOUT_SEC + 60) + "s") });
    }, (TIMEOUT_SEC + 60) * 1000);
    child.stdout.on("data", (d) => (stdout += d.toString("utf8")));
    child.stderr.on("data", (d) => (stderr += d.toString("utf8")));
    child.on("error", (e) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ status: null, stdout, stderr, error: e });
    });
    child.on("exit", (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ status: code, stdout, stderr, error: null });
    });
    child.stdin.write(script);
    child.stdin.end();
  });
  if (run.error) failures.push("dev-browser spawn error: " + String(run.error));
  elog(run.stderr || "");

  let inner = null;
  const stdout = run.stdout || "";
  for (const l of stdout.split("\n")) {
    if (l.startsWith("DBG")) elog(l);
  }
  const line = stdout.split("\n").find((l) => l.startsWith("HAUL_SHOTS_RESULT "));
  if (line) {
    try {
      inner = JSON.parse(line.slice("HAUL_SHOTS_RESULT ".length));
    } catch (e) {
      failures.push("could not parse the dev-browser result line: " + String(e));
    }
  } else {
    elog(stdout);
    failures.push("dev-browser did not print a HAUL_SHOTS_RESULT line (status=" + run.status + ")");
  }

  const allFailures = [...failures, ...((inner && inner.failures) || [])];
  const shots = [];
  if (inner && inner.shots) {
    for (const s of inner.shots) {
      if (existsSync(s.path)) {
        const dest = join(SCRATCH_DIR, s.board + ".png");
        copyFileSync(s.path, dest);
        shots.push({ board: s.board, path: dest });
      } else {
        allFailures.push("screenshot missing on disk for " + s.board + ": " + s.path);
      }
    }
  }

  const proof = inner ? inner.proof : {};
  if (doneCallTimestamps.length >= 2) {
    proof.doneAutoRetryMs = doneCallTimestamps[1] - doneCallTimestamps[0];
  }

  return { ok: allFailures.length === 0, failures: allFailures, proof, shots };
}

// -- compare-image build (Python/Pillow) -----------------------------------

const COMPARE_PY = `
import sys, json
from PIL import Image, ImageDraw, ImageFont

pairs = json.loads(sys.argv[1])
out_dir = sys.argv[2]

def load(path):
    if path and __import__("os").path.exists(path):
        return Image.open(path).convert("RGB")
    return None

for pair in pairs:
    board = pair["board"]
    canvas_img = load(pair.get("canvas"))
    app_paths = pair.get("app", [])
    app_imgs = [load(p) for p in app_paths]
    app_imgs = [im for im in app_imgs if im is not None]
    if canvas_img is None and not app_imgs:
        continue
    col_w = 390
    def scaled(im):
        if im is None:
            return None
        w, h = im.size
        if w == col_w:
            return im
        nh = int(h * col_w / w)
        return im.resize((col_w, nh), Image.LANCZOS)
    canvas_s = scaled(canvas_img)
    app_s = [scaled(im) for im in app_imgs]
    left_h = canvas_s.size[1] if canvas_s else 0
    right_h = sum(im.size[1] for im in app_s) + 12 * max(0, len(app_s) - 1)
    body_h = max(left_h, right_h, 100)
    title_h = 40
    gap = 16
    total_w = col_w * 2 + gap
    total_h = title_h + body_h
    canvas_out = Image.new("RGB", (total_w, total_h), (245, 242, 235))
    draw = ImageDraw.Draw(canvas_out)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 20)
    except Exception:
        font = ImageFont.load_default()
    draw.text((16, 10), board + "  (canvas left, app right)", fill=(30, 30, 30), font=font)
    if canvas_s:
        canvas_out.paste(canvas_s, (0, title_h))
    y = title_h
    for im in app_s:
        canvas_out.paste(im, (col_w + gap, y))
        y += im.size[1] + 12
    dest = out_dir + "/compare-" + board + ".png"
    canvas_out.save(dest)
    print(dest)
`;

function buildCompareImages(canvasDir, shots) {
  const byBoard = {};
  for (const s of shots) {
    const base = s.board.replace(/-with$|-without$|-after-new-haul$/, "");
    byBoard[base] = byBoard[base] || { canvas: null, app: [] };
  }
  // Map each app shot to its compare board.
  const groups = {
    Ready: { canvas: "Ready", app: ["Ready"] },
    FirstSnaps: { canvas: "FirstSnaps", app: ["FirstSnaps"] },
    GemsLanding: { canvas: "GemsLanding", app: ["GemsLanding"] },
    Gem: { canvas: "Gem", app: ["Gem"] },
    Finishing: { canvas: "Finishing", app: ["Finishing"] },
    Done: { canvas: "Done", app: ["Done"] },
    NoSignal: { canvas: "NoSignal", app: ["NoSignal"] },
    Failed: { canvas: "Failed", app: ["Failed"] },
    Stopped: { canvas: "Stopped", app: ["Stopped"] },
    EbayBlock: { canvas: "EbayBlock", app: ["EbayBlock-with", "EbayBlock-without"] },
  };
  const shotPath = (board) => {
    const found = shots.find((s) => s.board === board);
    return found ? found.path : null;
  };
  const pairs = [];
  for (const [board, cfg] of Object.entries(groups)) {
    pairs.push({
      board,
      canvas: join(canvasDir, cfg.canvas + ".png"),
      app: cfg.app.map(shotPath).filter(Boolean),
    });
  }
  const pyScriptPath = join(SCRATCH_DIR, "compare.py");
  writeFileSync(pyScriptPath, COMPARE_PY);
  const res = spawnSync("python3", [pyScriptPath, JSON.stringify(pairs), OUT_DIR], { encoding: "utf8" });
  if (res.status !== 0) {
    elog("compare image build failed:", res.stdout, res.stderr);
    return { ok: false, error: (res.stderr || "") + (res.stdout || "") };
  }
  return { ok: true, files: res.stdout.trim().split("\n").filter(Boolean) };
}

// -- click-path.md ----------------------------------------------------------

function writeClickPath(proof) {
  const rows = [
    ["Start haul (Ready)", "POST /api/hauls fires; phase moves to Active and the tally appears", proof.startHaul ? "ok — FirstSnaps board (haul-tally present after Start a haul)" : "FAILED — no proof recorded"],
    ["Add photos (multi input)", "Files queue client-side; the onPhone tile/tally count rises", proof.addPhotos ? "ok — GemsLanding/Finishing/NoSignal boards, " + JSON.stringify(proof.addPhotos) : "not recorded"],
    ["Snap (capture input)", "A single photo queues the same way as Add photos", proof.snap ? "ok — FirstSnaps board" : "not recorded"],
    ["Gem row open", "Tapping a closed row shows its .haul-gem-detail", proof.gemOpen ? "ok — Gem board, opened \"" + proof.gemOpen.label + "\"" : "FAILED — no proof recorded"],
    ["A second gem switches", "Opening another row closes the first (at most one open)", proof.gemSwitch ? "ok — .haul-gem-detail count after switch = " + proof.gemSwitch.detailCount + " (expected 1)" : "not recorded"],
    ["The same gem closes", "Tapping an open row's own header closes it", proof.gemClose ? "ok — .haul-gem-detail count after close = " + proof.gemClose.detailCount + " (expected 0)" : "not recorded"],
    ["Sold link href (blocked)", "a.scan-ebay-sold-btn points at ebay.com; the tap is blocked network-side", proof.soldLink ? "ok — href=" + proof.soldLink.href + (proof.soldLinkPopupBlocked ? ", popup opened then blocked (chrome-error, per route.abort)" : "") : "FAILED — no proof recorded"],
    ["Done (Finishing)", "Tapping Done moves phase to Finishing; the dock bar replaces the controls", proof.doneTapped ? "ok — Finishing board (.haul-bar present)" : "FAILED — no proof recorded"],
    ["Done auto-retry", "A failed Done retries once on its own after ~5 s (AppState.retryDelayMs(1))", proof.doneAutoRetryMs != null ? "ok — second POST /done arrived " + proof.doneAutoRetryMs + " ms after the first (Failed board)" : "not recorded — doneCalls=" + JSON.stringify(proof.doneCalls || [])],
    ["The receipt", "Once emailedAt is set, phase Finished shows the Haul Receipt section", proof.receiptShown ? "ok — Done board (section[aria-label='Haul receipt'])" : "FAILED — no proof recorded"],
    ["Start a new haul", "Tapping it on the receipt returns to the Ready screen (NoHaul)", proof.newHaul ? "ok — Done-after-new-haul shot (.haul-ready-start reappeared)" : "FAILED — no proof recorded"],
  ];
  let md = "# Haul UI click-path audit\n\n";
  md += "Run against a fresh FIXTURES=1 server, with every haul route mocked by a\n";
  md += "plain Node HTTP proxy in front of it (one board's canned JSON at a time),\n";
  md += "with data lifted from the design canvas's own GEMS/FAILS sample arrays.\n";
  md += "See scripts/haul-shots.mjs.\n\n";
  md += "| Control | What it must do | Proof |\n";
  md += "|---|---|---|\n";
  for (const [control, must, proofText] of rows) {
    md += "| " + control + " | " + must + " | " + proofText + " |\n";
  }
  return md;
}

main()
  .then(async (result) => {
    const canvasDir = argValue(
      "--canvas-dir",
      "/private/tmp/claude-501/-Users-dwight-code-reflip--claude-worktrees-priceless-williams-a1b440/f7d53f8d-6f57-4539-9be8-a416686f6022/scratchpad/canvas-shots"
    );
    let compare = { ok: false, files: [] };
    if (result.shots.length > 0) {
      compare = buildCompareImages(canvasDir, result.shots);
    }
    mkdirSync(OUT_DIR, { recursive: true });
    const clickPathPath = join(OUT_DIR, "click-path.md");
    writeFileSync(clickPathPath, writeClickPath(result.proof || {}));

    await cleanup();

    const final = {
      ok: result.ok && compare.ok,
      failures: [...result.failures, ...(compare.ok ? [] : [compare.error || "compare image build failed"])],
      proof: result.proof,
      shots: result.shots.map((s) => s.board),
      compareFiles: compare.files || [],
      clickPathPath,
      scratchDir: SCRATCH_DIR,
      ms: Date.now() - START,
    };
    console.log(JSON.stringify(final, null, 2));
    process.exit(final.ok ? 0 : 1);
  })
  .catch(async (e) => {
    await cleanup();
    console.log(JSON.stringify({ ok: false, failures: ["uncaught in haul-shots.mjs: " + String(e && e.stack ? e.stack : e)] }, null, 2));
    process.exit(1);
  });
