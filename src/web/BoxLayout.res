// Pure geometry for reflip item boxes — no DOM, so this compiles and runs
// under Node for tests, same as AppState.res. Two things: the crop each
// card's thumbnail shows (a 10% margin around the box, clamped to the
// photo, scaled to fit a small box) and the hit test for a tap on the
// photo (the smallest box that holds the tap point).
// src/tests/BoxLayoutTest.res exercises both directly.

// The div and background-image geometry for one card's crop, all in CSS
// pixels. App.res turns this into a style: the div is divWidth x
// divHeight, background-size is bgWidth x bgHeight, background-position is
// -bgX, -bgY (the sign flip happens at the call site, not here).
type crop = {
  divWidth: float,
  divHeight: float,
  bgWidth: float,
  bgHeight: float,
  bgX: float,
  bgY: float,
}

let cropOf = (box: Types.box, imageWidth: int, imageHeight: int): crop => {
  let bw = Int.toFloat(box.x2 - box.x1)
  let bh = Int.toFloat(box.y2 - box.y1)
  let marginX = bw *. 0.1
  let marginY = bh *. 0.1
  let cropX1 = Math.max(0.0, Int.toFloat(box.x1) -. marginX)
  let cropY1 = Math.max(0.0, Int.toFloat(box.y1) -. marginY)
  let cropX2 = Math.min(Int.toFloat(imageWidth), Int.toFloat(box.x2) +. marginX)
  let cropY2 = Math.min(Int.toFloat(imageHeight), Int.toFloat(box.y2) +. marginY)
  let cropW = cropX2 -. cropX1
  let cropH = cropY2 -. cropY1
  let scale = Math.min(96.0 /. cropW, 140.0 /. cropH)
  {
    divWidth: cropW *. scale,
    divHeight: cropH *. scale,
    bgWidth: Int.toFloat(imageWidth) *. scale,
    bgHeight: Int.toFloat(imageHeight) *. scale,
    bgX: cropX1 *. scale,
    bgY: cropY1 *. scale,
  }
}

let boxArea = (b: Types.box): int => (b.x2 - b.x1) * (b.y2 - b.y1)

let containsPoint = (b: Types.box, px: float, py: float): bool =>
  px >= Int.toFloat(b.x1) &&
  px <= Int.toFloat(b.x2) &&
  py >= Int.toFloat(b.y1) &&
  py <= Int.toFloat(b.y2)

// The smallest box (by area) that holds (px, py), in photo pixels. `None`
// for a tap outside every box. A nested pair of boxes (a small item drawn
// inside a shelf-sized box) resolves to the smaller one, so a tap on the
// item picks the item, not the shelf.
let hitTest = (boxes: array<option<Types.box>>, px: float, py: float): option<int> =>
  boxes
  ->Array.reduceWithIndex(None, (best, boxOpt, i) =>
    switch boxOpt {
    | Some(b) if containsPoint(b, px, py) =>
      let area = boxArea(b)
      switch best {
      | None => Some((i, area))
      | Some((_, bestArea)) => area < bestArea ? Some((i, area)) : best
      }
    | _ => best
    }
  )
  ->Option.map(((i, _)) => i)

// Non-overlapping half-sizes for the photo pins (this track's report): the
// <button class="scan-pin"> hit-boxes are all a fixed 44x44 today, so two
// pins closer than 44px apart overlap — paint order is DOM order (item
// number order, since siblings are z-index:auto), so the top one always
// wins, and a real click at a covered pin's center can open a NEIGHBOR's
// sheet instead. A z-index change cannot fix an overlapping hit-box, only
// a smaller one can.
//
// `centers` are photo-pixel box centers (the same space ScanView's own
// boxCenterPct takes as input) — Chebyshev distance there is
// scale-invariant under the photo's uniform on-screen scale
// (.scan-photo-img is width:100%, height:auto, so x and y share one scale
// factor from photo px to screen px), so a square computed in photo px
// stays a square on screen.
//
// h_i = chebyshevDistance(i, nearestOther(i)) / 2, in PHOTO px, with no
// clamp here. Proof of no overlap for EVERY pair i, j (not just
// nearest-neighbor pairs), in this photo-pixel space: d(i, nearest(i)) <=
// d(i, j) by definition of "nearest", so h_i <= d(i,j)/2; symmetrically
// h_j <= d(i,j)/2; so h_i + h_j <= d(i,j) — two axis-aligned squares of
// these half-sizes, centered on i and j, cannot overlap here, coincident
// pins (d==0) included (h_i = h_j = 0 then, no longer a floor-forced
// exception). A lone pin (no other center to measure against) gets
// `None` — unbounded, not a fixed max, since nothing constrains it.
//
// This module never sees the photo's on-screen CSS size, so it must not
// pick a tap-target floor or ceiling itself — that is a CSS-pixel
// quantity. A fixed clamp here was a unit bug: an earlier version
// clamped h to [4, 22] PHOTO px, then ScanView turned 2h into a percent
// of the photo's raw pixel width (1568px) — on a ~358 CSS-px-wide phone
// rendering, that 22px ceiling became about 10 CSS px and the 4px floor
// became about 1 CSS px, an almost untappable pin. The real [8px, 44px]
// floor and ceiling are applied downstream instead, in ScanView +
// scan.css, as `max(8px, min(44px, P%))` (see `pinSizeCss` below) —
// evaluated by the browser against the photo's actual rendered size, not
// by this module against the photo's pixel dimensions. Boxes can overlap
// on screen only where that CSS floor makes one or both bigger than the
// size proved safe above: two pins closer than the floor's on-screen
// equivalent (8 CSS px) at the current viewport.
// src/tests/BoxLayoutTest.res checks this.
let pinHalfSizes = (centers: array<(float, float)>): array<option<float>> => {
  let chebyshev = (x1: float, y1: float, x2: float, y2: float): float =>
    Math.max(Math.abs(x1 -. x2), Math.abs(y1 -. y2))
  centers->Array.mapWithIndex((c, i) => {
    let (cx, cy) = c
    let nearest = centers->Array.reduceWithIndex(None, (best, other, j) =>
      if j == i {
        best
      } else {
        let (ox, oy) = other
        let d = chebyshev(cx, cy, ox, oy)
        switch best {
        | None => Some(d)
        | Some(b) => Some(Math.min(b, d))
        }
      }
    )
    nearest->Option.map(d => d /. 2.0)
  })
}

// Self-contained on purpose, same reasoning as ScanView.res's own binding
// of the same JS method: this module has no DOM import, so it should not
// gain one just to format a percent string.
@send external toFixed: (float, int) => string = "toFixed"

// The CSS size for one pin button's width or height. `half` is this
// pin's half-size in photo px from `pinHalfSizes` (`None` for a lone
// pin); `totalPx` is the photo's own full width or height in photo px
// (model.sentWidth for width, model.sentHeight for height) that the
// percent is taken against.
//
// A lone pin has no neighbor to bound it, so it gets the flat CSS
// ceiling, 44px, directly — the percent math below never runs for it, so
// a huge photo can't blow it up either. Otherwise: `half*2` as a percent
// of `totalPx`, wrapped in CSS's own `max()`/`min()` so the BROWSER
// clamps it to [8px, 44px] at layout time, against the photo's actual
// on-screen CSS size — not against the photo-pixel value this module
// works in. That split matters: a percent of the photo's pixel width
// means a different CSS pixel count on a 1568px-wide desktop than on a
// ~358px-wide phone, so the clamp has to happen after the browser turns
// the percent into real CSS px, never before — see pinHalfSizes's own
// comment for the unit bug that shipped when it happened before.
let pinSizeCss = (half: option<float>, totalPx: float): string =>
  switch half {
  | None => "44px"
  | Some(h) =>
    let pct = totalPx > 0.0 ? h *. 2.0 /. totalPx *. 100.0 : 0.0
    "max(8px, min(44px, " ++ toFixed(pct, 2) ++ "%))"
  }
