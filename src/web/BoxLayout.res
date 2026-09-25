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
