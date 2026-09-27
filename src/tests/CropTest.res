// Crop.withMargin: hand-computed cases mirroring BoxLayoutTest.res's style
// for the same 10% margin rule. Crop.make: a real sips crop of the small
// fixture photo, checked against the same hand-computed math, plus the
// "never upscales" rule Thumb.make already guarantees and Crop.make
// inherits by reusing it.

let run = () => {
  TestKit.section("Crop.withMargin")

  // A box in the middle of an 800x600 photo: margin is 10% of the box's
  // own 200x200 size (20px) on each side, well clear of any clamp.
  TestKit.check(
    "a middle box gets a plain 10% margin",
    Crop.withMargin({Types.x1: 100, y1: 100, x2: 300, y2: 300}, ~width=800, ~height=600) ==
      {Types.x1: 80, y1: 80, x2: 320, y2: 320},
  )

  // Top-left corner: the box already touches x=0/y=0, so only the
  // low-side margin is clamped away; the high side still grows by margin.
  TestKit.check(
    "a box at the top-left corner clamps the low side",
    Crop.withMargin({Types.x1: 0, y1: 0, x2: 100, y2: 50}, ~width=800, ~height=600) ==
      {Types.x1: 0, y1: 0, x2: 110, y2: 55},
  )

  // Bottom-right corner: the mirror case, the high side clamps to the
  // photo's own width/height and the low side keeps its margin.
  TestKit.check(
    "a box at the bottom-right corner clamps the high side",
    Crop.withMargin({Types.x1: 700, y1: 550, x2: 800, y2: 600}, ~width=800, ~height=600) ==
      {Types.x1: 690, y1: 545, x2: 800, y2: 600},
  )

  // A tiny 10x10 box: margin is 1px a side, small enough that rounding
  // still lands on a clean pixel.
  TestKit.check(
    "a tiny box still gets a proportional margin",
    Crop.withMargin({Types.x1: 400, y1: 300, x2: 410, y2: 310}, ~width=800, ~height=600) ==
      {Types.x1: 399, y1: 299, x2: 411, y2: 311},
  )

  // A box already filling the whole photo: the margin pushes past both
  // edges on every side, so the clamp brings it right back to the photo's
  // own bounds, unchanged.
  TestKit.check(
    "a box filling the photo clamps to the photo on every side",
    Crop.withMargin({Types.x1: 0, y1: 0, x2: 800, y2: 600}, ~width=800, ~height=600) ==
      {Types.x1: 0, y1: 0, x2: 800, y2: 600},
  )

  TestKit.section("Crop.make")

  if !Node.Fs.existsSync("/usr/bin/sips") {
    Console.log("  skip - /usr/bin/sips not found, skipping Crop.make tests")
  } else {
    let tmpDir = Node.Path.join([Node.Os.tmpdir(), "reflip-crop-test-" ++ Node.Crypto.randomUUID()])
    Node.Fs.mkdirSync(tmpDir, {recursive: true})
    let source = Node.Path.join([Node.Process.cwd(), "tests/fixtures/table.jpg"])

    // tests/fixtures/table.jpg is 64x48 (see ThumbTest.res). This box and
    // margin land entirely inside the photo, so the crop isolates the
    // margin math from any clamp: bw=40, bh=30, margin 4x3, giving a
    // 48x36 crop region at offset (6, 7).
    let box: Types.box = {x1: 10, y1: 10, x2: 50, y2: 40}
    TestKit.check(
      "sanity: the hand-computed margin for this fixture box is 48x36 at (6, 7)",
      Crop.withMargin(box, ~width=64, ~height=48) == {Types.x1: 6, y1: 7, x2: 54, y2: 43},
    )

    // Default longEdge=240: the 48x36 crop is already smaller, so
    // Crop.make must not scale it up — same rule Thumb.make enforces.
    let notUpscaled = Node.Path.join([tmpDir, "not-upscaled.jpg"])
    switch Crop.make(~src=source, ~dest=notUpscaled, ~box, ~width=64, ~height=48) {
    | Error(e) => TestKit.check("Crop.make succeeds with the default longEdge: " ++ e, false)
    | Ok () => {
        let out = ChildProcess.execFileSync(
          Thumb.sipsPath,
          ["-g", "pixelWidth", "-g", "pixelHeight", notUpscaled],
          {ChildProcess.encoding: "utf8"},
        )
        switch Thumb.parseDimensions(out) {
        | Some((w, h)) => TestKit.check("a 48x36 crop under longEdge 240 is not scaled up", w == 48 && h == 36)
        | None => TestKit.check("could read back the crop's pixel size", false)
        }
      }
    }

    // An explicit longEdge smaller than the crop (24, against a 48x36
    // crop) forces the scale-down step: long edge 48 -> 24 halves both
    // sides, so the hand-computed output is 24x18.
    let scaled = Node.Path.join([tmpDir, "scaled.jpg"])
    switch Crop.make(~src=source, ~dest=scaled, ~box, ~width=64, ~height=48, ~longEdge=24) {
    | Error(e) => TestKit.check("Crop.make succeeds with longEdge=24: " ++ e, false)
    | Ok () => {
        let out = ChildProcess.execFileSync(
          Thumb.sipsPath,
          ["-g", "pixelWidth", "-g", "pixelHeight", scaled],
          {ChildProcess.encoding: "utf8"},
        )
        switch Thumb.parseDimensions(out) {
        | Some((w, h)) =>
          TestKit.check("a 48x36 crop scaled to longEdge 24 matches the hand-computed 24x18", w == 24 && h == 18)
        | None => TestKit.check("could read back the scaled crop's pixel size", false)
        }
      }
    }

    // The intermediate full-size crop file must not survive next to dest:
    // tmpDir is fresh to this test, so once both calls above are done, it
    // should hold exactly the two dest files and nothing else.
    let entries = Node.Fs.readdirSync(tmpDir)
    TestKit.check(
      "the intermediate crop temp file is removed, leaving only the two dest files",
      Array.length(entries) == 2 &&
        Array.includes(entries, "not-upscaled.jpg") &&
        Array.includes(entries, "scaled.jpg"),
    )
  }
}
