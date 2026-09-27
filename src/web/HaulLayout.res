// Pure Haul-view layout and text math, ported from
// docs/design/haul-ui/Main.dc.html's renderVals() (the design canvas for
// docs/haul-ui.md). No DOM, so this compiles and runs under Node for
// src/tests/HaulLayoutTest.res, the same way BoxLayout.res does for the
// old M0 item boxes. App.res and HaulView/GemCard turn these numbers and
// strings into JSX and CSS; this module never touches the DOM.

// -- Tally tiles and legend (docs/haul-ui.md decision 2) --------------------

type tileCounts = {
  valued: int,
  valuing: int,
  onPhone: int,
  notValued: int,
  failed: int,
}

// `stopped` is `stopReason->Option.isSome` — once a haul is stopped
// (budget reached), queued photos stop being counted as "valuing" and
// become "not valued" instead, since the server will not run them.
let tallyOf = (counts: Types.haulCounts, queueLen: int, stopped: bool): tileCounts => {
  valued: counts.valued,
  valuing: stopped ? counts.running : counts.queued + counts.running,
  onPhone: queueLen,
  notValued: stopped ? counts.queued : 0,
  failed: counts.failed,
}

// "{v} valued · {g} valuing · {p} on phone", plus the not-valued and
// failed clauses only when those counts are non-zero. `·` here is the
// exact U+00B7 middle dot from Main.dc.html line 658 — do not retype it.
let legendOf = (t: tileCounts): string =>
  Int.toString(t.valued) ++
  " valued · " ++
  Int.toString(t.valuing) ++
  " valuing · " ++
  Int.toString(t.onPhone) ++
  " on phone" ++
  (t.notValued > 0 ? " · " ++ Int.toString(t.notValued) ++ " not valued" : "") ++
  (t.failed > 0 ? " · " ++ Int.toString(t.failed) ++ " failed" : "")

// -- Budget bar (decision 3) --------------------------------------------

let budgetFillPct = (cost: float, max: float): float =>
  max <= 0.0 ? 0.0 : Math.min(cost, max) /. max

// The upload row's fill, 0.0 to 1.0 — same shape as budgetFillPct above.
// totalBytes is a photo's own size, always > 0 in practice, but a queue
// item mid-restore or a 0-byte blob must not divide by zero.
let uploadPct = (sentBytes: int, totalBytes: int): float =>
  totalBytes <= 0
    ? 0.0
    : Math.min(Int.toFloat(sentBytes), Int.toFloat(totalBytes)) /. Int.toFloat(totalBytes)

// One notch per photo boundary except the last, at an even split of the
// spend so far across `valued` photos — the API has no per-photo cost, so
// this is an approximation (decision 3 says so explicitly).
let notchPositions = (~costUsd: float, ~maxUsd: float, ~valued: int): array<float> =>
  if valued <= 1 || maxUsd <= 0.0 {
    []
  } else {
    let rec build = (k, acc) =>
      k >= valued
        ? acc
        : build(
            k + 1,
            Array.concat(
              acc,
              [Math.min(costUsd *. Int.toFloat(k) /. Int.toFloat(valued), maxUsd) /. maxUsd],
            ),
          )
    build(1, [])
  }

// -- Finishing bar text (decision 8) -------------------------------------

let lastN = (n: int): string =>
  n == 1 ? "the last photo" : "the last " ++ Int.toString(n) ++ " photos"

// Real ellipsis character `…` (U+2026), copied from Main.dc.html, not
// three periods.
let finishingText = (~onPhone: int, ~valuing: int): string =>
  if onPhone > 0 {
    "Sending " ++ lastN(onPhone) ++ "…"
  } else if valuing > 0 {
    "Done. Valuing " ++ lastN(valuing) ++ ", then the digest goes out."
  } else {
    "Done. Sending the digest…"
  }

// -- Offline notice (decision 7) -----------------------------------------

// Curly apostrophe `'` (U+2019) in "Can't", copied from Main.dc.html
// line 785, not a straight quote.
let offlineText = (onPhone: int): string =>
  "Can’t reach reflip. " ++
  (
    onPhone == 1
      ? "1 photo is safe on the phone and sends on its own."
      : Int.toString(onPhone) ++ " photos are safe on the phone and send on their own."
  )

// -- Crop geometry (ported from canvas crop(b), Main.dc.html L435-448) ----

// The 358x184 detail crop a gem's open row shows: the photo positioned so
// the gem's own box is centered and padded, plus the box outline itself,
// all in CSS pixels against the 358x184 frame. `x0`/`y0`/`k` are exposed
// (not just the 8 px fields) because pinsOn below needs them to place
// OTHER gems' number stickers inside this same crop window.
type cropGeometry = {
  x0: float,
  y0: float,
  k: float,
  imgLeftPx: float,
  imgTopPx: float,
  imgWidthPx: float,
  imgHeightPx: float,
  boxLeftPx: float,
  boxTopPx: float,
  boxWidthPx: float,
  boxHeightPx: float,
}

let cropOf = (box: Types.box, ~imageWidth: int, ~imageHeight: int): cropGeometry => {
  let iw = Int.toFloat(imageWidth)
  let ih = Int.toFloat(imageHeight)
  let x1 = Int.toFloat(box.x1)
  let y1 = Int.toFloat(box.y1)
  let x2 = Int.toFloat(box.x2)
  let y2 = Int.toFloat(box.y2)
  // Frame aspect ratio (width / height) of the 358x184 crop window.
  let frameAspect = 358.0 /. 184.0
  let w0 = Math.max((x2 -. x1) *. 1.3, 460.0)
  let h0 = (y2 -. y1) *. 1.3
  // Enforce the frame's aspect ratio: grow whichever side is short.
  let (w1, h1) = w0 /. h0 < frameAspect ? (h0 *. frameAspect, h0) : (w0, w0 /. frameAspect)
  // Canvas clamps against its own fixed PHOTO_W; a real photo varies, so
  // clamp against the actual imageWidth instead.
  let (w, h) = w1 > iw ? (iw, iw /. frameAspect) : (w1, h1)
  let x0 = Math.max(0.0, Math.min(iw -. w, (x1 +. x2) /. 2.0 -. w /. 2.0))
  let y0 = Math.max(0.0, Math.min(ih -. h, (y1 +. y2) /. 2.0 -. h /. 2.0))
  let k = 358.0 /. w
  {
    x0,
    y0,
    k,
    imgLeftPx: -.x0 *. k,
    imgTopPx: -.y0 *. k,
    imgWidthPx: iw *. k,
    imgHeightPx: ih *. k,
    boxLeftPx: (x1 -. x0) *. k,
    boxTopPx: (y1 -. y0) *. k,
    boxWidthPx: (x2 -. x1) *. k,
    boxHeightPx: (y2 -. y1) *. k,
  }
}

// -- Thumb geometry (ported from canvas thumb(b), Main.dc.html L449-455) --

// The 44x44 round thumbnail a gem row shows: a square window centered on
// the box (no outline — the thumb never draws the box, just crops around
// it).
type thumbGeometry = {
  imgLeftPx: float,
  imgTopPx: float,
  imgWidthPx: float,
  imgHeightPx: float,
}

let thumbOf = (box: Types.box, ~imageWidth: int, ~imageHeight: int): thumbGeometry => {
  let iw = Int.toFloat(imageWidth)
  let ih = Int.toFloat(imageHeight)
  let x1 = Int.toFloat(box.x1)
  let y1 = Int.toFloat(box.y1)
  let x2 = Int.toFloat(box.x2)
  let y2 = Int.toFloat(box.y2)
  let side = Math.min(Math.max(x2 -. x1, y2 -. y1) *. 1.2, ih)
  let x0 = Math.max(0.0, Math.min(iw -. side, (x1 +. x2) /. 2.0 -. side /. 2.0))
  let y0 = Math.max(0.0, Math.min(ih -. side, (y1 +. y2) /. 2.0 -. side /. 2.0))
  let k = 44.0 /. side
  {
    imgLeftPx: -.x0 *. k,
    imgTopPx: -.y0 *. k,
    imgWidthPx: iw *. k,
    imgHeightPx: ih *. k,
  }
}

// -- Pins: other gems' stickers on an open gem's crop (decision 4; ported
// from canvas detailOf's `pins`, Main.dc.html L703-709) -------------------

type pin = {
  num: string,
  leftPx: float,
  topPx: float,
  rotateDeg: int,
}

// A small pseudo-random rotation so the stickers don't all sit dead
// level — ported verbatim from canvas's `tilt(n)`.
let tilt = (n: int): int => mod(n * 37, 17) - 8

// `others` is every OTHER gem on the same photo as the open one, as
// (rank, box) — rank is the 1-based index into status.gems (decision 4),
// which the caller already knows and this module does not recompute.
let pinsOn = (~crop: cropGeometry, ~others: array<(int, Types.box)>): array<pin> =>
  others
  ->Array.map(((num, box)) => {
    let cx = (Int.toFloat(box.x1 + box.x2) /. 2.0 -. crop.x0) *. crop.k
    let cy = (Int.toFloat(box.y1 + box.y2) /. 2.0 -. crop.y0) *. crop.k
    (num, cx, cy)
  })
  ->Array.filter(((_, cx, cy)) => cx >= 8.0 && cx <= 350.0 && cy >= 8.0 && cy <= 176.0)
  ->Array.map(((num, cx, cy)) => {
    num: Int.toString(num),
    leftPx: cx -. 13.0,
    topPx: cy -. 13.0,
    rotateDeg: tilt(num),
  })

// -- eBay range bar (ported from canvas bar(g), Main.dc.html L456-471,
// cross-checked against EbayBlock.dc.html's rendered pixel values) -------

// The caller supplies each label's already-formatted text (`labMin`/
// `labMed`/`labMax` for the eBay stats, 2-decimal per decision 12;
// `bandText` for "Claude's $lo–hi", whole-dollar per decision 12) because
// this module stays free of a money formatter of its own — it only needs
// each string's length, to keep a label from overflowing the 328px track
// (canvas's `at(v, text)` approximates a label's rendered width as
// `text.length * 6.6`, a deliberate simplification, not a bug to fix).
type barGeometry = {
  labMinLeftPx: float,
  labMedLeftPx: float,
  labMaxLeftPx: float,
  lineLeftPx: float,
  lineWidthPx: float,
  tickMinLeftPx: float,
  tickMaxLeftPx: float,
  medLeftPx: float,
  bandLeftPx: float,
  bandWidthPx: float,
  bandTextLeftPx: float,
}

let barWidthPx = 328.0

let barOf = (
  ~ebay: Types.ebayStats,
  ~lowUsd: float,
  ~highUsd: float,
  ~labMin: string,
  ~labMed: string,
  ~labMax: string,
  ~bandText: string,
): barGeometry => {
  let lo = Math.min(ebay.minUsd, lowUsd)
  let hi = Math.max(ebay.maxUsd, highUsd)
  let x = v => (v -. lo) /. (hi -. lo) *. barWidthPx
  let at = (v, text) => {
    let w = Int.toFloat(String.length(text)) *. 6.6
    Math.max(0.0, Math.min(barWidthPx -. w, x(v) -. w /. 2.0))
  }
  {
    labMinLeftPx: at(ebay.minUsd, labMin),
    labMedLeftPx: at(ebay.medianUsd, labMed),
    labMaxLeftPx: at(ebay.maxUsd, labMax),
    lineLeftPx: x(ebay.minUsd),
    lineWidthPx: x(ebay.maxUsd) -. x(ebay.minUsd),
    tickMinLeftPx: x(ebay.minUsd) -. 0.75,
    tickMaxLeftPx: x(ebay.maxUsd) -. 0.75,
    medLeftPx: x(ebay.medianUsd) -. 1.5,
    bandLeftPx: x(lowUsd),
    bandWidthPx: x(highUsd) -. x(lowUsd),
    bandTextLeftPx: at((lowUsd +. highUsd) /. 2.0, bandText),
  }
}

// -- A CSS pixel string, one decimal place, same as canvas's px() helper --

let pxStr = (v: float): string => Float.toFixed(v, ~digits=1) ++ "px"

// -- The walk ticket's clock (decision 6) --------------------------------

// Zero-pad to two digits (canvas's two()).
let two = (n: int): string => n < 10 ? "0" ++ Int.toString(n) : Int.toString(n)

// Elapsed time since the haul started: "m:ss" under an hour, "h:mm:ss"
// after (decision 6). This is only the text formatting — App.res's
// HaulClock leaf component owns the 1s tick and the Date math that
// produces `elapsedSeconds`, so a model tick does not add a rewind entry
// every second.
let clockText = (elapsedSeconds: int): string => {
  let v = elapsedSeconds < 0 ? 0 : elapsedSeconds
  let h = v / 3600
  let m = mod(v, 3600) / 60
  let s = mod(v, 60)
  h > 0 ? Int.toString(h) ++ ":" ++ two(m) ++ ":" ++ two(s) : Int.toString(m) ++ ":" ++ two(s)
}

// -- Receipt time and stamp date (decision 9) -----------------------------

// Local clock time, browser zone — canvas's timeOf(): "3:07 PM". Tests
// check the shape only, never an exact hour: the hour depends on the
// machine's zone, which src/tests/HaulLayoutTest.res must not assume.
let timeOf = (iso: string): string => {
  let d = Date.fromString(iso)
  let h24 = Date.getHours(d)
  let m = Date.getMinutes(d)
  let period = h24 >= 12 ? "PM" : "AM"
  let h12 = mod(h24, 12) == 0 ? 12 : mod(h24, 12)
  Int.toString(h12) ++ ":" ++ two(m) ++ " " ++ period
}

// Three-letter month name for the stamp date, always upper case.
let monthAbbrev = (m: int): string =>
  switch m {
  | 0 => "JAN"
  | 1 => "FEB"
  | 2 => "MAR"
  | 3 => "APR"
  | 4 => "MAY"
  | 5 => "JUN"
  | 6 => "JUL"
  | 7 => "AUG"
  | 8 => "SEP"
  | 9 => "OCT"
  | 10 => "NOV"
  | _ => "DEC"
  }

// The receipt stamp date, local zone — canvas's "SEP 26 2026". Comes
// from emailedAt (decision 9).
let stampDateOf = (iso: string): string => {
  let d = Date.fromString(iso)
  monthAbbrev(Date.getMonth(d)) ++
  " " ++
  Int.toString(Date.getDate(d)) ++
  " " ++
  Int.toString(Date.getFullYear(d))
}
