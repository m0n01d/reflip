// Box.decode: one test for each case in docs/spec-item-boxes.md's "Shape"
// section — missing, wrong length, a degenerate box, fully outside, a
// partly-outside clamp, an unchanged high-tier box, and a standard-tier
// (Haiku) rescale.

let run = () => {
  TestKit.section("Box.decode")

  TestKit.check(
    "missing box gives None",
    Box.decode(None, ~sentWidth=800, ~sentHeight=600, ~model=Shared.Sonnet5) == None,
  )

  TestKit.check(
    "not exactly 4 numbers gives None",
    Box.decode(
      Some([1.0, 2.0, 3.0]),
      ~sentWidth=800,
      ~sentHeight=600,
      ~model=Shared.Sonnet5,
    ) == None,
  )

  TestKit.check(
    "x2 <= x1 gives None",
    Box.decode(
      Some([200.0, 100.0, 100.0, 300.0]),
      ~sentWidth=800,
      ~sentHeight=600,
      ~model=Shared.Sonnet5,
    ) == None,
  )

  TestKit.check(
    "y2 <= y1 gives None",
    Box.decode(
      Some([100.0, 300.0, 200.0, 300.0]),
      ~sentWidth=800,
      ~sentHeight=600,
      ~model=Shared.Sonnet5,
    ) == None,
  )

  // Sonnet 5 is the high tier: an 800x600 photo fits with no resize, so
  // `seen` equals `sent` and a box fully outside [0,800]x[0,600] is None.
  TestKit.check(
    "a box fully outside the seen photo gives None",
    Box.decode(
      Some([900.0, 700.0, 1000.0, 800.0]),
      ~sentWidth=800,
      ~sentHeight=600,
      ~model=Shared.Sonnet5,
    ) == None,
  )

  // Same 800x600, no resize: a box fully inside comes back unchanged.
  TestKit.check(
    "an unchanged box on the high tier (no resize) keeps its coordinates",
    Box.decode(
      Some([50.0, 60.0, 700.0, 550.0]),
      ~sentWidth=800,
      ~sentHeight=600,
      ~model=Shared.Sonnet5,
    ) == Some({Types.x1: 50, y1: 60, x2: 700, y2: 550}),
  )

  // sent == seen here too (1270x952 already fits the standard tier), so
  // this isolates the clamp from any rescale: a box partly outside
  // [0,1270]x[0,952] clamps to it.
  TestKit.check(
    "a partly-outside box clamps to the seen photo",
    Box.decode(
      Some([-50.0, -20.0, 300.0, 200.0]),
      ~sentWidth=1270,
      ~sentHeight=952,
      ~model=Shared.Haiku4_5,
    ) == Some({Types.x1: 0, y1: 0, x2: 300, y2: 200}),
  )

  // Haiku 4.5 is the standard tier: a 1600x1200 photo resizes to 1270x952
  // (ImageSizeTest.res checks that resize on its own), so the brain must
  // rescale the box back onto the 1600x1200 photo the page actually sent.
  // 100*1600/1270 = 125.98... -> 126, 100*1200/952 = 126.05... -> 126,
  // 500*1600/1270 = 629.92... -> 630, 400*1200/952 = 504.20... -> 504.
  TestKit.check(
    "a Haiku 4.5 box rescales from the resized photo back to the sent photo",
    Box.decode(
      Some([100.0, 100.0, 500.0, 400.0]),
      ~sentWidth=1600,
      ~sentHeight=1200,
      ~model=Shared.Haiku4_5,
    ) == Some({Types.x1: 126, y1: 126, x2: 630, y2: 504}),
  )
}
