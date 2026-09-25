// Test entry point: npm test -> node src/tests/AllTests.res.mjs
// node:assert throws on failure, so a non-zero exit fails the run.

StatsTest.run()
PricingTest.run()
ClaudeDecodeTest.run()
EbayDecodeTest.run()
GuardTest.run()
StoreTest.run()
AppStateTest.run()
DigestTest.run()
EmailTest.run()
ThumbTest.run()
Console.log("all sync tests passed")

// Async suite (the live HTTP server): a rejection here fails the process
// exit code (node >= 15), same as dippa's src/tests/AllTests.res.
let () =
  ServerTest.run()
  ->Promise.then(() => SharedDecodeTest.run())
  ->Promise.then(() => StaticServeTest.run())
  ->Promise.then(() => ClaudeTimeoutTest.run())
  ->Promise.then(() => HaulTest.run())
  ->Promise.then(() => HaulEmailTest.run())
  ->Promise.then(() => {
      Console.log("all tests passed")
      Promise.resolve()
    })
  ->Promise.ignore
