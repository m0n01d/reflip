// Thumb.make shells out to /usr/bin/sips, so this test is skipped (loudly)
// on a machine without it rather than failing the whole suite.

let run = () => {
  TestKit.section("Thumb.make")

  if !Node.Fs.existsSync("/usr/bin/sips") {
    Console.log("  skip - /usr/bin/sips not found, skipping Thumb.make tests")
  } else {
    let tmpDir = Node.Path.join([Node.Os.tmpdir(), "reflip-thumb-test-" ++ Node.Crypto.randomUUID()])
    Node.Fs.mkdirSync(tmpDir, {recursive: true})
    let source = Node.Path.join([Node.Process.cwd(), "tests/fixtures/table.jpg"])

    // Build a known 1200x800 test source by upscaling the small fixture
    // directly with sips's exact-size flag. Thumb.make itself never
    // upscales, so it can't be used to build this fixture.
    let big = Node.Path.join([tmpDir, "big.jpg"])
    let _ = ChildProcess.execFileSync(
      "/usr/bin/sips",
      ["-z", "800", "1200", source, "--out", big],
      {ChildProcess.encoding: "utf8"},
    )

    let dest = Node.Path.join([tmpDir, "thumb.jpg"])
    switch Thumb.make(~src=big, ~dest, ~longEdge=480) {
    | Error(e) => TestKit.check("Thumb.make succeeds on a 1200x800 source: " ++ e, false)
    | Ok () => {
        TestKit.check("Thumb.make writes the destination file", Node.Fs.existsSync(dest))
        let out = ChildProcess.execFileSync(
          "/usr/bin/sips",
          ["-g", "pixelWidth", "-g", "pixelHeight", dest],
          {ChildProcess.encoding: "utf8"},
        )
        switch Thumb.parseDimensions(out) {
        | Some((w, h)) => {
            TestKit.check("thumbnail long edge scales down to 480", (w > h ? w : h) == 480)
            TestKit.check("thumbnail short edge stays under 480 too", h <= 480 && w <= 480)
          }
        | None => TestKit.check("could read back the thumbnail's pixel size", false)
        }
      }
    }

    // Never upscales: a source already under the target long edge is
    // copied as-is, not scaled up.
    let small = Node.Path.join([tmpDir, "small.jpg"])
    switch Thumb.make(~src=source, ~dest=small, ~longEdge=480) {
    | Error(e) => TestKit.check("Thumb.make succeeds on an already-small source: " ++ e, false)
    | Ok () => {
        let out = ChildProcess.execFileSync(
          "/usr/bin/sips",
          ["-g", "pixelWidth", "-g", "pixelHeight", small],
          {ChildProcess.encoding: "utf8"},
        )
        switch Thumb.parseDimensions(out) {
        | Some((w, h)) => TestKit.check("a small source is copied, not upscaled", w == 64 && h == 48)
        | None => TestKit.check("could read back the copied file's pixel size", false)
        }
      }
    }
  }
}
