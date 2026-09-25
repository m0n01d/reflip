// Test entry point: npm test -> node src/tests/AllTests.res.mjs
// node:assert throws on failure, so a non-zero exit fails the run.

StatsTest.run()
PricingTest.run()
ImageSizeTest.run()
JpegSizeTest.run()
BoxTest.run()
ClaudeDecodeTest.run()
EbayDecodeTest.run()
GuardTest.run()
StoreTest.run()
AppStateTest.run()
DigestTest.run()
ThumbTest.run()
CropTest.run()
ScaleRefTest.run()
BoxLayoutTest.run()
Console.log("all sync tests passed")

// Async suite (the live HTTP server, plus EmailTest's stream-transport
// send): a rejection here fails the process exit code (node >= 15), same
// as dippa's src/tests/AllTests.res.
let () =
  EmailTest.run()
  ->Promise.then(() => ServerTest.run())
  ->Promise.then(() => SharedDecodeTest.run())
  ->Promise.then(() => StaticServeTest.run())
  ->Promise.then(() => ClaudeTimeoutTest.run())
  ->Promise.then(() => ClaudeCutOffTest.run())
  ->Promise.then(() => HaulTest.run())
  ->Promise.then(() => HaulEmailTest.run())
  ->Promise.then(() => {
      Console.log("all tests passed")
      Promise.resolve()
    })
  ->Promise.ignore
