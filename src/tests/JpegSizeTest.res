// JpegSize.dimensions against the fixture photo (its true size checked with
// `sips -g pixelWidth -g pixelHeight tests/fixtures/table.jpg`) and against
// a non-JPEG buffer.

let run = () => {
  TestKit.section("JpegSize.dimensions")

  let path = Node.Path.join([Node.Process.cwd(), "tests/fixtures/table.jpg"])
  let buf = Node.Fs.readFileBuffer(path)
  switch JpegSize.dimensions(buf) {
  | Some((width, height)) =>
    TestKit.check(
      "table.jpg is 64x48 (per sips -g pixelWidth -g pixelHeight)",
      width == 64 && height == 48,
    )
  | None => TestKit.check("table.jpg's dimensions decode", false)
  }

  let notJpeg = Node.Buffer.fromString("not a jpeg at all, just some text bytes", "utf8")
  TestKit.check("a non-JPEG buffer gives None", JpegSize.dimensions(notJpeg) == None)
}
