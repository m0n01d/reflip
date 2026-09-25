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
// h_i = clamp(chebyshevDistance(i, nearestOther(i)) / 2, minHalf, maxHalf).
// Proof of no overlap for EVERY pair i, j (not just nearest-neighbor
// pairs): d(i, nearest(i)) <= d(i, j) by definition of "nearest", so
// h_i <= d(i,j)/2; symmetrically h_j <= d(i,j)/2; so h_i + h_j <= d(i,j) —
// two axis-aligned squares of these half-sizes, centered on i and j,
// cannot overlap. A lone pin (no other center to measure against) gets
// maxHalf. Coincident pins (d==0) both clamp to minHalf — the one case
// the floor cannot fully fix (two pins on the exact same spot can't both
// get non-overlapping boxes). src/tests/BoxLayoutTest.res checks this.
let pinHalfSizes = (centers: array<(float, float)>): array<float> => {
  let minHalf = 4.0
  let maxHalf = 22.0 // half of the current fixed 44px
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
    switch nearest {
    | None => maxHalf
    | Some(d) => Math.max(minHalf, Math.min(maxHalf, d /. 2.0))
    }
  })
}
