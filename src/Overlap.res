// Pure IoU (intersection over union) box matching, used to pair a spot-pass
// box (name + box, no price) with the priced item whose box it overlaps —
// see docs/scan-ui.md §1 decision 2. Node-free: src/web/ can import this
// too, same as Shared.res and Box.res's own decode logic.

// Intersection over union of two boxes in the same pixel space (Types.box,
// per Box.res's decode). 0.0 when the boxes do not overlap, or when either
// box has zero area.
let iou = (a: Types.box, b: Types.box): float => {
  let ix1 = a.x1 > b.x1 ? a.x1 : b.x1
  let iy1 = a.y1 > b.y1 ? a.y1 : b.y1
  let ix2 = a.x2 < b.x2 ? a.x2 : b.x2
  let iy2 = a.y2 < b.y2 ? a.y2 : b.y2
  let iw = ix2 - ix1
  let ih = iy2 - iy1
  let interArea = iw > 0 && ih > 0 ? iw * ih : 0
  let areaA = (a.x2 - a.x1) * (a.y2 - a.y1)
  let areaB = (b.x2 - b.x1) * (b.y2 - b.y1)
  let unionArea = areaA + areaB - interArea
  unionArea <= 0 ? 0.0 : Int.toFloat(interArea) /. Int.toFloat(unionArea)
}

// The candidate with the highest IoU against `box`, at or above `threshold`
// (0.5 by default — an IoU of exactly the threshold counts as a match, per
// docs/scan-ui.md §1 decision 2). A tie goes to the lower index. None when
// no candidate clears the threshold.
let bestMatch = (
  ~box: Types.box,
  ~candidates: array<(int, Types.box)>,
  ~threshold: float=0.5,
): option<int> =>
  Array.reduce(candidates, None, (best, (idx, candidateBox)) => {
    let score = iou(box, candidateBox)
    if score < threshold {
      best
    } else {
      switch best {
      | None => Some((idx, score))
      | Some((bestIdx, bestScore)) =>
        score > bestScore || (score == bestScore && idx < bestIdx)
          ? Some((idx, score))
          : Some((bestIdx, bestScore))
      }
    }
  })->Option.map(((idx, _)) => idx)
