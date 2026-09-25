// Second, short dev-browser script for scripts/haul-smoke.mjs's cleanup.
// CONFIG ({ port }) is prepended the same way as haul-smoke.browser.js.
//
// A dev-browser script that hits its own --timeout loses its console output
// and leaves its page open (reflip-smoke-gotchas memory note). That open
// page keeps holding the phone page's IndexedDB, which stalls the next run.
// This closes any page left open against this run's port.

const list = await browser.listPages();
const prefix = "http://127.0.0.1:" + CONFIG.port;
const targets = list.filter((p) => typeof p.url === "string" && p.url.indexOf(prefix) === 0);
let closed = 0;
for (const t of targets) {
  try {
    const p = await browser.getPage(t.id);
    await p.close();
    closed++;
  } catch (e) {}
}
console.log("HAUL_SMOKE_CLEANUP " + JSON.stringify({ closed, total: list.length }));
