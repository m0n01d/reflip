// BoxLayout.cropOf and BoxLayout.hitTest: no DOM, so this runs under Node
// like AppStateTest.res. See docs/spec-item-boxes.md's "How it works" and
// "Shape" sections for the crop math (a 10% margin, clamped to the photo,
// scaled to fit 96x140) and the hit-test rule (the smallest box wins).

let run = () => {
  TestKit.section("BoxLayout")

  // -- cropOf: a normal box, comfortably inside the photo -------------------
  let normalBox: Types.box = {x1: 100, y1: 100, x2: 200, y2: 300}
  let c1 = BoxLayout.cropOf(normalBox, 1000, 1000)
  // box is 100x200; a 10% margin is 10x20, so the crop is [90,210]x[80,320]
  // = 120x240 (well inside [0,1000]x[0,1000], so no clamp).
  // scale = min(96/120, 140/240) = min(0.8, 0.58333...) = 140/240.
  let expectedScale1 = 140.0 /. 240.0
  TestKit.approx("normal box: div width", c1.divWidth, 120.0 *. expectedScale1, ~eps=0.01)
  TestKit.approx("normal box: div height", c1.divHeight, 240.0 *. expectedScale1, ~eps=0.01)
  TestKit.approx("normal box: bg width", c1.bgWidth, 1000.0 *. expectedScale1, ~eps=0.01)
  TestKit.approx("normal box: bg height", c1.bgHeight, 1000.0 *. expectedScale1, ~eps=0.01)
  TestKit.approx("normal box: bg x offset", c1.bgX, 90.0 *. expectedScale1, ~eps=0.01)
  TestKit.approx("normal box: bg y offset", c1.bgY, 80.0 *. expectedScale1, ~eps=0.01)

  // -- cropOf: a box at the photo edge, so the margin clamps ----------------
  let edgeBox: Types.box = {x1: 0, y1: 900, x2: 100, y2: 1000}
  let c2 = BoxLayout.cropOf(edgeBox, 1000, 1000)
  // box is 100x100; a 10% margin is 10x10. x1 - 10 clamps to 0 (not -10),
  // y2 + 10 clamps to 1000 (not 1010). Crop is [0,110]x[890,1000] = 110x110.
  let expectedScale2 = Math.min(96.0 /. 110.0, 140.0 /. 110.0)
  TestKit.approx("edge box: div width", c2.divWidth, 110.0 *. expectedScale2, ~eps=0.01)
  TestKit.approx("edge box: div height", c2.divHeight, 110.0 *. expectedScale2, ~eps=0.01)
  TestKit.approx("edge box: bg x offset is clamped to 0", c2.bgX, 0.0, ~eps=0.01)
  TestKit.approx("edge box: bg y offset", c2.bgY, 890.0 *. expectedScale2, ~eps=0.01)

  // -- hitTest: a miss gives None --------------------------------------------
  let boxes: array<option<Types.box>> = [
    Some({Types.x1: 0, y1: 0, x2: 100, y2: 100}),
    Some({Types.x1: 20, y1: 20, x2: 40, y2: 40}),
    None,
  ]
  TestKit.check(
    "a tap outside every box gives None",
    BoxLayout.hitTest(boxes, 500.0, 500.0) == None,
  )

  // -- hitTest: a nested box picks the smaller one ---------------------------
  TestKit.check(
    "a tap inside both boxes picks the smaller (nested) one",
    BoxLayout.hitTest(boxes, 30.0, 30.0) == Some(1),
  )
  TestKit.check(
    "a tap inside only the larger box picks it",
    BoxLayout.hitTest(boxes, 5.0, 5.0) == Some(0),
  )

  // -- pinHalfSizes: two pins 20px apart split the gap evenly ---------------
  // Chebyshev distance is 20 (only x differs); half of that is 10, inside
  // [minHalf=4, maxHalf=22], so no clamp fires.
  TestKit.check(
    "two pins 20px apart both get half-size 10",
    BoxLayout.pinHalfSizes([(100.0, 100.0), (120.0, 100.0)]) == [10.0, 10.0],
  )

  // -- pinHalfSizes: a lone pin has no neighbor, so it gets the max ---------
  TestKit.check(
    "a lone pin gets the max half-size 22 (no other center to measure against)",
    BoxLayout.pinHalfSizes([(50.0, 50.0)]) == [22.0],
  )

  // -- pinHalfSizes: coincident pins (distance 0) both clamp to the floor ---
  // The documented can't-fix case: two pins on the exact same spot cannot
  // both get non-overlapping boxes, so both clamp to minHalf.
  TestKit.check(
    "two pins at the same spot both get the floor half-size 4",
    BoxLayout.pinHalfSizes([(70.0, 70.0), (70.0, 70.0)]) == [4.0, 4.0],
  )

  // -- pinHalfSizes: a dense generated grid never lets two boxes overlap ----
  // A 5x5 grid at 10px spacing (>= 2*minHalf=8, so the floor cannot force
  // an overlap). For every pair i,j, h_i + h_j <= chebyshev(i,j) must hold,
  // or the two axis-aligned squares centered on i and j would overlap.
  let gridRows = [0, 1, 2, 3, 4]
  let gridCols = [0, 1, 2, 3, 4]
  let grid = gridRows->Array.reduce([], (acc, row) =>
    Array.concat(
      acc,
      gridCols->Array.map(col => (Int.toFloat(col) *. 10.0, Int.toFloat(row) *. 10.0)),
    )
  )
  let gridHalves = BoxLayout.pinHalfSizes(grid)
  let chebyshev = (x1: float, y1: float, x2: float, y2: float): float =>
    Math.max(Math.abs(x1 -. x2), Math.abs(y1 -. y2))
  let epsilon = 0.001
  let noOverlap = grid->Array.reduceWithIndex(true, (okSoFar, p1, i) => {
    let (x1, y1) = p1
    let hi = Option.getOr(Array.get(gridHalves, i), 0.0)
    grid->Array.reduceWithIndex(okSoFar, (ok, p2, j) =>
      if j <= i {
        ok
      } else {
        let (x2, y2) = p2
        let hj = Option.getOr(Array.get(gridHalves, j), 0.0)
        ok && (hi +. hj <= chebyshev(x1, y1, x2, y2) +. epsilon)
      }
    )
  })
  TestKit.check("no two boxes overlap on a dense 5x5 grid at 10px spacing", noOverlap)
}
