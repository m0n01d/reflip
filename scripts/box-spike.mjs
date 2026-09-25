// Item-boxes spike (docs/spec-item-boxes.md, "Spike first").
//
// For each photo: bake in the EXIF rotation, resize, strip the metadata, send
// it to Sonnet 5 with no web search, and ask for item names and [x1, y1, x2, y2]
// pixel boxes through output_config.format. Then draw the boxes with
// dev-browser and save everything to data/boxes/.
//
//   node --env-file-if-exists=$HOME/.config/reflip/env scripts/box-spike.mjs \
//     [--size 1568|max] [--dry] [--draw-only] <photo>...
//
// --size 1568  long edge 1568, the same scale math as src/web/Resize.res.
// --size max   the largest size that Sonnet 5 takes with no resize, from the
//              reference function in the vision-coordinates guide (never upscales).
// --dry        resize only, no Claude call.
// --draw-only  redraw from the saved JSON, no Claude call.
//
// macOS only: it uses sips, and exiftool from Homebrew.

import { execFileSync, spawnSync } from "node:child_process"
import { mkdirSync, readFileSync, writeFileSync, copyFileSync, appendFileSync } from "node:fs"
import { basename, extname, join } from "node:path"
import { homedir, tmpdir } from "node:os"

const MODEL = "claude-sonnet-5"
const INPUT_PER_MTOK = 2 // src/Pricing.res, checked 2026-09-24
const OUTPUT_PER_MTOK = 10
const HIGH_RES = { maxEdge: 2576, maxTokens: 4784 } // Opus 5.5 and Sonnet 5
const OUT_DIR = "data/boxes"
const JAIL = join(homedir(), ".dev-browser", "tmp")

// ---- sizes -----------------------------------------------------------------

// src/web/Resize.res scaleDims: long edge at most longEdge, never upscale.
const scaleDims = (w, h, longEdge) => {
  const longSide = Math.max(w, h)
  if (longSide <= longEdge) return [w, h]
  const scale = longEdge / longSide
  return [Math.max(1, Math.trunc(w * scale)), Math.max(1, Math.trunc(h * scale))]
}

// Reference resize function from platform.claude.com/docs/en/build-with-claude/vision-coordinates.
const countImageTokens = (w, h) => Math.ceil(w / 28) * Math.ceil(h / 28)
const roundTiesToEven = v => {
  const f = Math.floor(v)
  if (v - f !== 0.5) return Math.round(v)
  return f % 2 === 0 ? f : f + 1
}
const resizedSize = (width, height, maxEdge = 1568, maxTokens = 1568) => {
  const fits = (w, h) =>
    Math.ceil(w / 28) * 28 <= maxEdge && Math.ceil(h / 28) * 28 <= maxEdge && countImageTokens(w, h) <= maxTokens
  if (fits(width, height)) return [width, height]
  if (height > width) {
    const [rh, rw] = resizedSize(height, width, maxEdge, maxTokens)
    return [rw, rh]
  }
  const aspect = width / height
  let lo = 1
  let hi = width
  while (lo + 1 < hi) {
    const mid = Math.floor((lo + hi) / 2)
    if (fits(mid, Math.max(roundTiesToEven(mid / aspect), 1))) lo = mid
    else hi = mid
  }
  return [lo, Math.max(roundTiesToEven(lo / aspect), 1)]
}

// ---- image prep ------------------------------------------------------------

const run = (cmd, args) => execFileSync(cmd, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] })
const dims = file => {
  const out = run("sips", ["-g", "pixelWidth", "-g", "pixelHeight", file])
  return [Number(/pixelWidth: (\d+)/.exec(out)[1]), Number(/pixelHeight: (\d+)/.exec(out)[1])]
}

// sips works on the stored pixels and keeps the EXIF tag, so rotate by the tag
// first, then strip every tag (orientation and GPS) after the resize.
const ROTATE = { 1: null, 3: "180", 6: "90", 8: "270" }

const prepare = (src, size, work) => {
  const tag = run("exiftool", ["-n", "-s3", "-Orientation", src]).trim() || "1"
  if (!(tag in ROTATE)) throw new Error(`${src}: EXIF orientation ${tag} is a mirror, not handled`)
  const upright = join(work, "upright.jpg")
  const rot = ROTATE[tag] ? ["-r", ROTATE[tag]] : []
  run("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "100", ...rot, src, "--out", upright])
  const [w, h] = dims(upright)
  const [tw, th] = size === "max" ? resizedSize(w, h, HIGH_RES.maxEdge, HIGH_RES.maxTokens) : scaleDims(w, h, 1568)
  const out = join(work, "sent.jpg")
  run("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "85", "-z", String(th), String(tw), upright, "--out", out])
  run("exiftool", ["-q", "-all=", "-overwrite_original", out])
  const [ow, oh] = dims(out)
  if (ow !== tw || oh !== th) throw new Error(`${src}: sips gave ${ow}x${oh}, wanted ${tw}x${th}`)
  const left = run("exiftool", ["-n", "-s3", "-Orientation", out]).trim()
  if (left) throw new Error(`${src}: orientation tag ${left} survived the strip`)
  return { file: out, srcW: w, srcH: h, w: tw, h: th, tag }
}

// ---- Claude ----------------------------------------------------------------

const schema = {
  type: "object",
  properties: {
    items: {
      type: "array",
      items: {
        type: "object",
        properties: {
          name: { type: "string" },
          box: { type: "array", items: { type: "integer" } },
        },
        required: ["name", "box"],
        additionalProperties: false,
      },
    },
  },
  required: ["items"],
  additionalProperties: false,
}

const promptFor = (w, h) =>
  `This photo is ${w} pixels wide and ${h} pixels tall. ` +
  `List each distinct item in it that a person could resell, for example each board game on a shelf. ` +
  `Give each item a short name, and its bounding box as [x1, y1, x2, y2]: the top-left and bottom-right corners, ` +
  `as integer pixel coordinates in this photo. x runs from 0 at the left edge to ${w} at the right edge. ` +
  `y runs from 0 at the top edge to ${h} at the bottom edge. ` +
  `The box holds all of the visible item and as little else as possible. ` +
  `List the items from left to right, then top to bottom.`

const callClaude = async (apiKey, b64, w, h) => {
  const body = {
    model: MODEL,
    max_tokens: 8192,
    messages: [
      {
        role: "user",
        content: [
          {
            type: "image",
            source: { type: "base64", media_type: "image/jpeg", data: b64 },
            transformations: { oversized_image: "error" },
          },
          { type: "text", text: promptFor(w, h) },
        ],
      },
    ],
    output_config: { format: { type: "json_schema", schema } },
  }
  const start = Date.now()
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(180_000),
  })
  const ms = Date.now() - start
  const json = await res.json()
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${JSON.stringify(json.error ?? json)}`)
  const text = json.content.filter(b => b.type === "text").map(b => b.text).join("")
  const items = JSON.parse(text).items
  const u = json.usage
  const cost = (u.input_tokens * INPUT_PER_MTOK + u.output_tokens * OUTPUT_PER_MTOK) / 1e6
  return { items, usage: u, stopReason: json.stop_reason, ms, cost, raw: json }
}

// ---- drawing ---------------------------------------------------------------

const drawAll = names => {
  if (names.length === 0) return
  const script = `
const NAMES = ${JSON.stringify(names)};
const page = await browser.getPage("reflip-boxes");
for (const name of NAMES) {
  const job = JSON.parse(await readFile("reflip-boxes-job-" + name + ".json"));
  // The photo at its sent size, then a legend panel on the right: "N name".
  const legendW = Math.round(Math.max(job.w, job.h) * 0.3);
  const fullW = job.w + legendW;
  const cssW = Math.min(fullW, 1800);
  const cssH = Math.round(job.h * cssW / fullW);
  await page.setViewportSize({ width: cssW, height: cssH });
  await page.setContent('<html><body style="margin:0;background:#000"><canvas id="c" width="' + fullW + '" height="' + job.h + '" style="width:' + cssW + 'px;height:' + cssH + 'px;display:block"></canvas></body></html>');
  await page.evaluate(async ({ job, legendW }) => {
    const img = new Image();
    img.src = "data:image/jpeg;base64," + job.b64;
    await img.decode();
    const ctx = document.getElementById("c").getContext("2d");
    ctx.fillStyle = "#111";
    ctx.fillRect(job.w, 0, legendW, job.h);
    ctx.drawImage(img, 0, 0);
    const unit = Math.max(job.w, job.h);
    const lw = Math.max(3, Math.round(unit / 400));
    const tag = Math.max(14, Math.round(unit / 70));
    const n = job.items.length;
    const line = Math.min(Math.round(unit / 45), Math.floor((job.h - 20) / Math.max(n, 1)));
    job.items.forEach((it, i) => {
      const [x1, y1, x2, y2] = it.box;
      const color = "hsl(" + ((i * 137.5) % 360) + " 95% 55%)";
      ctx.lineWidth = lw;
      ctx.strokeStyle = "#000";
      ctx.strokeRect(x1, y1, x2 - x1, y2 - y1);
      ctx.lineWidth = lw - 1;
      ctx.strokeStyle = color;
      ctx.strokeRect(x1, y1, x2 - x1, y2 - y1);
      const num = String(i + 1);
      ctx.font = "bold " + tag + "px sans-serif";
      const tw = ctx.measureText(num).width;
      ctx.fillStyle = color;
      ctx.fillRect(x1, y1, tw + 8, tag + 6);
      ctx.fillStyle = "#000";
      ctx.fillText(num, x1 + 4, y1 + tag);
      ctx.font = "bold " + Math.round(line * 0.8) + "px sans-serif";
      ctx.fillStyle = color;
      ctx.fillText(num + "  " + it.name, job.w + 10, 10 + line * (i + 1) - Math.round(line * 0.2), legendW - 20);
    });
  }, { job, legendW });
  await saveScreenshot(await page.locator("#c").screenshot({ type: "jpeg", quality: 85 }), "reflip-boxes-" + name + ".jpg");
  console.log("drew " + name);
}
`
  const r = spawnSync("dev-browser", ["--headless", "--timeout", "600"], { input: script, encoding: "utf8" })
  process.stdout.write(r.stdout)
  if (r.status !== 0) throw new Error(`dev-browser failed: ${r.stderr}`)
  for (const name of names) copyFileSync(join(JAIL, `reflip-boxes-${name}.jpg`), join(OUT_DIR, `${name}.jpg`))
}

// ---- main ------------------------------------------------------------------

const args = process.argv.slice(2)
const flag = f => {
  const i = args.indexOf(f)
  if (i < 0) return false
  args.splice(i, 1)
  return true
}
const sizeIdx = args.indexOf("--size")
const size = sizeIdx >= 0 ? args.splice(sizeIdx, 2)[1] : "1568"
if (size !== "1568" && size !== "max") throw new Error("--size is 1568 or max")
const dry = flag("--dry")
const drawOnly = flag("--draw-only")
const photos = args
if (photos.length === 0) {
  console.error("usage: box-spike.mjs [--size 1568|max] [--dry] [--draw-only] <photo>...")
  process.exit(2)
}

const apiKey = process.env.ANTHROPIC_API_KEY
if (!dry && !drawOnly && !apiKey) {
  console.error("ANTHROPIC_API_KEY is not set. Run with node --env-file-if-exists=$HOME/.config/reflip/env")
  process.exit(2)
}

mkdirSync(OUT_DIR, { recursive: true })
const work = join(tmpdir(), `reflip-box-spike-${process.pid}`)
mkdirSync(work, { recursive: true })

const drawn = []
let total = 0
for (const src of photos) {
  const name = `${basename(src, extname(src))}-${size}`
  const jsonPath = join(OUT_DIR, `${name}.json`)
  const sentPath = join(OUT_DIR, `${name}-sent.jpg`)
  let rec
  if (drawOnly) {
    rec = JSON.parse(readFileSync(jsonPath, "utf8"))
  } else {
    const p = prepare(src, size, work)
    copyFileSync(p.file, sentPath)
    const tokens = countImageTokens(p.w, p.h)
    const line = `${name}: source ${p.srcW}x${p.srcH} (EXIF ${p.tag}), sent ${p.w}x${p.h}, ${tokens} visual tokens`
    if (dry) {
      console.log(line)
      continue
    }
    const b64 = readFileSync(p.file).toString("base64")
    const r = await callClaude(apiKey, b64, p.w, p.h)
    rec = {
      photo: basename(src),
      size,
      w: p.w,
      h: p.h,
      srcW: p.srcW,
      srcH: p.srcH,
      model: MODEL,
      date: new Date().toISOString(),
      ms: r.ms,
      usage: r.usage,
      stopReason: r.stopReason,
      cost: r.cost,
      items: r.items,
    }
    writeFileSync(jsonPath, JSON.stringify(rec, null, 2))
    writeFileSync(join(OUT_DIR, `${name}.raw.json`), JSON.stringify(r.raw, null, 2))
    appendFileSync(
      join(OUT_DIR, "costs.tsv"),
      [rec.date, name, `${p.w}x${p.h}`, r.usage.input_tokens, r.usage.output_tokens, r.items.length, r.ms, r.cost.toFixed(5)].join("\t") + "\n",
    )
    total += r.cost
    console.log(`${line}, ${r.items.length} items, in ${r.usage.input_tokens} out ${r.usage.output_tokens}, ${r.ms} ms, $${r.cost.toFixed(4)}, stop ${r.stopReason}`)
  }
  const b64 = readFileSync(sentPath).toString("base64")
  const bad = rec.items.filter(it => !Array.isArray(it.box) || it.box.length !== 4)
  if (bad.length) console.log(`${name}: ${bad.length} items without a four-number box, not drawn`)
  const items = rec.items.filter(it => Array.isArray(it.box) && it.box.length === 4)
  writeFileSync(join(JAIL, `reflip-boxes-job-${name}.json`), JSON.stringify({ w: rec.w, h: rec.h, b64, items }))
  drawn.push(name)
}

if (!dry) {
  drawAll(drawn)
  if (!drawOnly) console.log(`total cost $${total.toFixed(4)} for ${drawn.length} calls`)
}
