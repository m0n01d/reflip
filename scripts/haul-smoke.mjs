#!/usr/bin/env node
// A repeatable fixture-mode smoke test of the phone haul view (PR #15's gem
// cards, crops and box overlays), driven by dev-browser.
//
//   node scripts/haul-smoke.mjs [--n 5] [--out data/smoke/<stamp>] [--skip-build]
//                                [--headed] [--timeout 180] [--keep-data]
//
// It builds the app, starts src/Main.res.mjs in fixture mode on a free
// port with a throwaway DATA_DIR and no live secrets, uploads
// tests/fixtures/table.jpg n times, waits for the haul to finish, then
// drives every gem card and one sold-listings link through dev-browser
// (scripts/haul-smoke.browser.js). It prints one JSON line to stdout and
// exits 0 only when every check passed. Everything else goes to stderr.
//
// See ~/.claude/projects/-Users-dwight-code-reflip/memory/reflip-smoke-gotchas.md
// for the fixture-photo-size and IndexedDB gotchas this script works around.

import { spawn, spawnSync } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  rmSync,
  readFileSync,
  writeFileSync,
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

const N = parseInt(argValue("--n", "5"), 10);
const HEADED = hasFlag("--headed");
const SKIP_BUILD = hasFlag("--skip-build");
const KEEP_DATA = hasFlag("--keep-data");
const TIMEOUT_SEC = parseInt(argValue("--timeout", "180"), 10);
const stamp = new Date().toISOString().replace(/[:.]/g, "-");
const OUT_DIR_ARG = argValue("--out", join("data", "smoke", stamp));
const OUT_DIR = join(REPO_ROOT, OUT_DIR_ARG);

const JAIL = join(homedir(), ".dev-browser", "tmp");
const BROWSER_NAME = "reflip-smoke";
const START = Date.now();

const runId = "haulsmoke-" + Date.now() + "-" + Math.random().toString(36).slice(2, 8);
const b64Name = runId + "-table.jpg.b64";
const shotPrefix = runId;
const shotSuffixes = ["closed", "open-box", "open-nobox", "sold"];

mkdirSync(OUT_DIR, { recursive: true });

let serverProc = null;
let dataDir = null;
let port = null;
let cleaned = false;

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
  const b64Path = join(JAIL, b64Name);
  if (existsSync(b64Path)) {
    try {
      rmSync(b64Path);
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
    elog("\nhaul-smoke: " + sig + ", cleaning up…");
    await cleanup();
    process.exit(130);
  });
}

// -- main -------------------------------------------------------------------

async function main() {
  const failures = [];

  if (!SKIP_BUILD) {
    elog("haul-smoke: npm run build");
    const build = spawnSync("npm", ["run", "build"], { cwd: REPO_ROOT, encoding: "utf8" });
    elog(build.stdout || "");
    elog(build.stderr || "");
    if (build.status !== 0) {
      failures.push("npm run build failed with exit code " + build.status);
      return finish(failures, null);
    }
  }

  port = await findFreePort();
  dataDir = mkdtempSync(join(tmpdir(), "reflip-smoke-"));
  elog("haul-smoke: port " + port + ", DATA_DIR " + dataDir);

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

  const serverLogPath = join(OUT_DIR, "server.log");
  const serverLogFd = openSync(serverLogPath, "a");
  serverProc = spawn("node", ["src/Main.res.mjs"], {
    cwd: REPO_ROOT,
    env: childEnv,
    stdio: ["ignore", serverLogFd, serverLogFd],
  });
  serverProc.on("exit", (code, signal) => {
    if (!cleaned) elog("haul-smoke: server exited early, code=" + code + " signal=" + signal);
  });

  try {
    await waitForServer(port, 20_000);
  } catch (e) {
    closeSync(serverLogFd);
    failures.push(String(e));
    return finish(failures, null);
  }
  closeSync(serverLogFd);

  const fixturePhoto = readFileSync(join(REPO_ROOT, "tests/fixtures/table.jpg"));
  mkdirSync(JAIL, { recursive: true });
  writeFileSync(join(JAIL, b64Name), fixturePhoto.toString("base64"));

  const config = { port, n: N, shotPrefix, b64Name, timeoutSec: TIMEOUT_SEC };
  const body = readFileSync(join(__dirname, "haul-smoke.browser.js"), "utf8");
  const script = "const CONFIG = " + JSON.stringify(config) + ";\n" + body;

  const devBrowserArgs = ["--browser", BROWSER_NAME, "--timeout", String(TIMEOUT_SEC)];
  if (!HEADED) devBrowserArgs.push("--headless");

  elog("haul-smoke: dev-browser " + devBrowserArgs.join(" "));
  const run = spawnSync("dev-browser", devBrowserArgs, {
    input: script,
    encoding: "utf8",
    maxBuffer: 20 * 1024 * 1024,
    timeout: (TIMEOUT_SEC + 60) * 1000,
  });
  elog(run.stderr || "");

  let inner = null;
  const stdout = run.stdout || "";
  const line = stdout.split("\n").find((l) => l.startsWith("HAUL_SMOKE_RESULT "));
  if (line) {
    try {
      inner = JSON.parse(line.slice("HAUL_SMOKE_RESULT ".length));
    } catch (e) {
      failures.push("could not parse the dev-browser result line: " + String(e));
    }
  } else {
    elog(stdout);
    failures.push(
      "dev-browser did not print a HAUL_SMOKE_RESULT line (status=" + run.status + ", error=" + (run.error || "") + ")"
    );
  }

  return finish(failures, inner);
}

function finish(wrapperFailures, inner) {
  const failures = [...wrapperFailures, ...((inner && inner.failures) || [])];
  const shots = [];
  for (const suffix of shotSuffixes) {
    const src = join(JAIL, shotPrefix + "-" + suffix + ".png");
    if (existsSync(src)) {
      const dest = join(OUT_DIR, suffix + ".png");
      try {
        copyFileSync(src, dest);
        shots.push(dest);
      } catch (e) {
        failures.push("could not copy screenshot " + suffix + ": " + String(e));
      }
    }
  }

  const result = {
    ok: failures.length === 0,
    failures,
    n: N,
    port,
    haulId: inner ? inner.haulId : null,
    counts: inner ? inner.counts : null,
    emailNote: inner ? inner.emailNote : null,
    gemCount: inner ? inner.gemCount : null,
    cropsMissing: inner ? inner.cropsMissing : null,
    cards: inner ? inner.cards : [],
    soldLink: inner ? inner.soldLink : null,
    idbDelete: inner ? inner.idbDelete : null,
    consoleErrors: inner ? inner.consoleErrors : [],
    photoRoute: inner ? inner.photoRoute : null,
    ms: Date.now() - START,
    outDir: OUT_DIR,
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
        failures: ["uncaught in haul-smoke.mjs: " + String(e && e.stack ? e.stack : e)],
        n: N,
        port,
        outDir: OUT_DIR,
        ms: Date.now() - START,
      })
    );
    process.exit(1);
  });
