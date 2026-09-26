#!/usr/bin/env node
// A repeatable fixture-mode browser check of the phone haul view's place
// slice (docs/haul-map-build.md's "Checks in a browser" C1), driven by
// dev-browser. Copies the structure of scripts/haul-smoke.mjs.
//
//   node scripts/place-check.mjs [--skip-build] [--out data/place-check/<stamp>]
//                                [--headed] [--timeout 180] [--keep-data]
//
// It builds the app, starts src/Main.res.mjs in fixture mode on a free port
// with a throwaway DATA_DIR and no live secrets, then drives seven cases
// through dev-browser (scripts/place-check.browser.js): a saved gps fix, a
// haul id that arrives late, the outbox after a reload, a denied prompt, a
// failed-then-retried prompt, the outbox surviving a reload that happens
// after Done and the email note, and (in this wrapper, not the browser
// script, since it needs the server's own log file) a privacy check that
// the brain's stdout/stderr never name the coordinates used in the other
// cases. It prints one JSON result line to stdout and exits 0 only when
// every case passed. Everything else goes to stderr.
//
// See ~/.claude/projects/-Users-dwight-code-reflip/memory/reflip-smoke-gotchas.md
// for the fixture-photo-size and IndexedDB gotchas this script also has to
// work around (deleteDatabase blocked while the app page is open, a timed-
// out dev-browser script leaving pages open, etc).

import { spawn, spawnSync } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  rmSync,
  readFileSync,
  copyFileSync,
  existsSync,
  openSync,
  closeSync,
} from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import net from "node:net";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = process.cwd();

// -- args ---------------------------------------------------------------

function argValue(name, def) {
  const i = process.argv.indexOf(name);
  return i === -1 ? def : process.argv[i + 1];
}
function hasFlag(name) {
  return process.argv.includes(name);
}

const HEADED = hasFlag("--headed");
const SKIP_BUILD = hasFlag("--skip-build");
const KEEP_DATA = hasFlag("--keep-data");
const TIMEOUT_SEC = parseInt(argValue("--timeout", "180"), 10);
const stamp = new Date().toISOString().replace(/[:.]/g, "-");
const OUT_DIR_ARG = argValue("--out", join("data", "place-check", stamp));
const OUT_DIR = join(REPO_ROOT, OUT_DIR_ARG);

const JAIL = join(homedir(), ".dev-browser", "tmp");
const BROWSER_NAME = "reflip-place";
const START = Date.now();

const runId = "placecheck-" + Date.now() + "-" + Math.random().toString(36).slice(2, 8);
const shotPrefix = runId;
const shotSuffixes = ["saved", "not-sent", "denied", "failed", "done-reload"];
const shotFileNames = {
  saved: "place-saved.png",
  "not-sent": "place-not-sent.png",
  denied: "place-denied.png",
  failed: "place-failed.png",
  "done-reload": "place-done-reload.png",
};

// The two case-1 fixture coordinates (Anchorage, AK). Case 6 (privacy)
// asserts neither string ever reaches the brain's stdout/stderr.
const CASE1_LAT = "61.2181";
const CASE1_LON = "149.9003"; // longitude is negative on the wire; the digits are what must stay out of the log

mkdirSync(OUT_DIR, { recursive: true });

let serverProc = null;
let dataDir = null;
let port = null;
let cleaned = false;
let serverLogPath = null;

function elog(...a) {
  console.error(...a);
}

// -- free port ------------------------------------------------------------

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

// -- cleanup ---------------------------------------------------------------

async function cleanup() {
  if (cleaned) return;
  cleaned = true;
  if (serverProc && !serverProc.killed) {
    try {
      serverProc.kill("SIGTERM");
    } catch (e) {}
  }
  for (const suffix of shotSuffixes) {
    const p = join(JAIL, shotPrefix + "-" + suffix + ".png");
    if (existsSync(p)) {
      try {
        rmSync(p);
      } catch (e) {}
    }
  }
  if (port != null) {
    try {
      const cleanupBody = readFileSync(join(__dirname, "haul-smoke.cleanup.browser.js"), "utf8");
      const cleanupScript = "const CONFIG = " + JSON.stringify({ port }) + ";\n" + cleanupBody;
      spawnSync("dev-browser", ["--browser", BROWSER_NAME, "--headless", "--timeout", "20"], {
        input: cleanupScript,
        encoding: "utf8",
        timeout: 30_000,
      });
    } catch (e) {
      elog("cleanup dev-browser script failed:", e);
    }
  }
  if (dataDir && !KEEP_DATA && existsSync(dataDir)) {
    try {
      rmSync(dataDir, { recursive: true, force: true });
    } catch (e) {}
  }
}

let interrupted = false;
for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, async () => {
    interrupted = true;
    elog("\nplace-check: " + sig + ", cleaning up…");
    await cleanup();
    process.exit(130);
  });
}

// -- main -------------------------------------------------------------------

async function main() {
  const failures = [];

  if (!SKIP_BUILD) {
    elog("place-check: npm run build");
    const build = spawnSync("npm", ["run", "build"], { cwd: REPO_ROOT, encoding: "utf8" });
    elog(build.stdout || "");
    elog(build.stderr || "");
    if (build.status !== 0) {
      failures.push("npm run build failed with exit code " + build.status);
      return finish(failures, null);
    }
  }

  port = await findFreePort();
  dataDir = mkdtempSync(join(tmpdir(), "reflip-place-check-"));
  elog("place-check: port " + port + ", DATA_DIR " + dataDir);

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

  serverLogPath = join(OUT_DIR, "server.log");
  const serverLogFd = openSync(serverLogPath, "a");
  serverProc = spawn("node", ["src/Main.res.mjs"], {
    cwd: REPO_ROOT,
    env: childEnv,
    stdio: ["ignore", serverLogFd, serverLogFd],
  });
  serverProc.on("exit", (code, signal) => {
    if (!cleaned) elog("place-check: server exited early, code=" + code + " signal=" + signal);
  });

  try {
    await waitForServer(port, 20_000);
  } catch (e) {
    closeSync(serverLogFd);
    failures.push(String(e));
    return finish(failures, null);
  }

  const config = { port, shotPrefix, timeoutSec: TIMEOUT_SEC };
  const body = readFileSync(join(__dirname, "place-check.browser.js"), "utf8");
  const script = "const CONFIG = " + JSON.stringify(config) + ";\n" + body;

  const devBrowserArgs = ["--browser", BROWSER_NAME, "--timeout", String(TIMEOUT_SEC)];
  if (!HEADED) devBrowserArgs.push("--headless");

  elog("place-check: dev-browser " + devBrowserArgs.join(" "));
  const run = spawnSync("dev-browser", devBrowserArgs, {
    input: script,
    encoding: "utf8",
    maxBuffer: 20 * 1024 * 1024,
    timeout: (TIMEOUT_SEC + 60) * 1000,
  });
  elog(run.stderr || "");

  let inner = null;
  const stdout = run.stdout || "";
  const line = stdout.split("\n").find((l) => l.startsWith("PLACE_CHECK_RESULT "));
  if (line) {
    try {
      inner = JSON.parse(line.slice("PLACE_CHECK_RESULT ".length));
    } catch (e) {
      failures.push("could not parse the dev-browser result line: " + String(e));
    }
  } else {
    elog(stdout);
    failures.push(
      "dev-browser did not print a PLACE_CHECK_RESULT line (status=" + run.status + ", error=" + (run.error || "") + ")"
    );
  }

  // Case 6: privacy. The brain's own log (stdout+stderr, this whole run)
  // must never carry either fixture-position substring. Read it after the
  // browser script's HTTP calls are all done, but before we kill the
  // server, so nothing is missed.
  closeSync(serverLogFd);
  let logText = "";
  try {
    logText = readFileSync(serverLogPath, "utf8");
  } catch (e) {
    failures.push("could not read the server log: " + String(e));
  }
  const privacy = { lat: !logText.includes(CASE1_LAT), lon: !logText.includes(CASE1_LON) };
  if (!privacy.lat || !privacy.lon) {
    failures.push(
      "the brain's stdout/stderr named a fixture coordinate: lat ok=" + privacy.lat + " lon ok=" + privacy.lon
    );
  }

  return finish(failures, inner, privacy);
}

function finish(wrapperFailures, inner, privacy) {
  const failures = [...wrapperFailures, ...((inner && inner.failures) || [])];
  const shots = {};
  for (const suffix of shotSuffixes) {
    const src = join(JAIL, shotPrefix + "-" + suffix + ".png");
    if (existsSync(src)) {
      const dest = join(OUT_DIR, shotFileNames[suffix]);
      try {
        copyFileSync(src, dest);
        shots[suffix] = dest;
      } catch (e) {
        failures.push("could not copy screenshot " + suffix + ": " + String(e));
      }
    }
  }

  const result = {
    ok: failures.length === 0,
    failures,
    port,
    cases: inner ? inner.cases : {},
    privacy: privacy || null,
    ms: Date.now() - START,
    outDir: OUT_DIR,
    serverLog: serverLogPath,
    shots,
  };
  return result;
}

main()
  .then(async (result) => {
    await cleanup();
    console.log(JSON.stringify(result));
    process.exit(result.ok ? 0 : 1);
  })
  .catch(async (e) => {
    await cleanup();
    console.log(
      JSON.stringify({
        ok: false,
        failures: ["uncaught in place-check.mjs: " + String(e && e.stack ? e.stack : e)],
        port,
        outDir: OUT_DIR,
        ms: Date.now() - START,
      })
    );
    process.exit(1);
  });
