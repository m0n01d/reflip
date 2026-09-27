// Overlap.iou and Overlap.bestMatch: docs/scan-ui.md §1 decision 2's
// "IoU under 0.5" boundary, and bestMatch's tie-break rule.

let run = () => {
  TestKit.section("Overlap")

  let square: Types.box = {Types.x1: 10, y1: 10, x2: 50, y2: 50}
  TestKit.approx("same box gives IoU 1.0", Overlap.iou(square, square), 1.0, ~eps=0.0001)

  let disjointA: Types.box = {Types.x1: 0, y1: 0, x2: 10, y2: 10}
  let disjointB: Types.box = {Types.x1: 20, y1: 20, x2: 30, y2: 30}
  TestKit.approx("disjoint boxes give IoU 0.0", Overlap.iou(disjointA, disjointB), 0.0, ~eps=0.0001)

  // a = (0,0,10,10) area 100, b = (5,5,15,15) area 100, intersection =
  // (5,5,10,10) area 25, union = 100 + 100 - 25 = 175, IoU = 25/175.
  let overlapA: Types.box = {Types.x1: 0, y1: 0, x2: 10, y2: 10}
  let overlapB: Types.box = {Types.x1: 5, y1: 5, x2: 15, y2: 15}
  TestKit.approx(
    "hand-computed partial overlap",
    Overlap.iou(overlapA, overlapB),
    25.0 /. 175.0,
    ~eps=0.0001,
  )

  let zeroWidth: Types.box = {Types.x1: 10, y1: 10, x2: 10, y2: 50}
  let normal: Types.box = {Types.x1: 0, y1: 0, x2: 20, y2: 60}
  TestKit.approx("a zero-area box gives IoU 0.0", Overlap.iou(zeroWidth, normal), 0.0, ~eps=0.0001)

  // a = (0,0,10,10) area 100 fully inside b = (0,0,10,20) area 200:
  // intersection = 100, union = 100 + 200 - 100 = 200, IoU = 0.5 exactly.
  let containedA: Types.box = {Types.x1: 0, y1: 0, x2: 10, y2: 10}
  let containerB: Types.box = {Types.x1: 0, y1: 0, x2: 10, y2: 20}
  TestKit.approx("exactly 0.5, hand-computed", Overlap.iou(containedA, containerB), 0.5, ~eps=0.0001)
  TestKit.check(
    "bestMatch: an IoU of exactly the threshold still matches",
    Overlap.bestMatch(~box=containedA, ~candidates=[(0, containerB)]) == Some(0),
  )

  // Two candidates score an identical, non-zero IoU against `box`; index 5
  // sits first in the array, but the lower index (2) must win the tie.
  let tieBox: Types.box = {Types.x1: 0, y1: 0, x2: 10, y2: 10}
  TestKit.check(
    "bestMatch: a tie goes to the lower index, regardless of array order",
    Overlap.bestMatch(~box=tieBox, ~candidates=[(5, tieBox), (2, tieBox)]) == Some(2),
  )
}
