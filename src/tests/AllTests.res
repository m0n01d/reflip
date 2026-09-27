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
PlaceTest.run()
HaulListTest.run()
AppStateTest.run()
DigestTest.run()
ThumbTest.run()
CropTest.run()
ScaleRefTest.run()
BoxLayoutTest.run()
HaulLayoutTest.run()
SseTest.run()
ItemScannerTest.run()
SceneStreamTest.run()
SpotPassTest.run()
ScanEventTest.run()
OverlapTest.run()
ScanStateTest.run()
ScanApiTest.run()
Console.log("all sync tests passed")

// Async suites (the live HTTP server, plus EmailTest's stream-transport
// send) run one at a time, in this order. If one rejects, the catch prints
// the error, the suite and the last TestKit.section, then exits with 1.
// Without it, Node reports an unhandled rejection, and a TimeoutError from
// an AbortSignal.timeout guard has only timer frames in its stack.
let asyncSuites: array<(string, unit => promise<unit>)> = [
  ("EmailTest", EmailTest.run),
  ("ServerTest", ServerTest.run),
  ("SharedDecodeTest", SharedDecodeTest.run),
  ("StaticServeTest", StaticServeTest.run),
  ("ClaudeTimeoutTest", ClaudeTimeoutTest.run),
  ("FixtureReplayTest", FixtureReplayTest.run),
  ("ClaudeCutOffTest", ClaudeCutOffTest.run),
  ("HaulTest", HaulTest.run),
  ("HaulEmailTest", HaulEmailTest.run),
  ("StreamRouteTest", StreamRouteTest.run),
  ("StreamRouteCutOffTest", StreamRouteCutOffTest.run),
  ("StreamRouteSpotTest", StreamRouteSpotTest.run),
  ("StreamRouteFetchFailTest", StreamRouteFetchFailTest.run),
  ("StreamRouteEbayFailTest", StreamRouteEbayFailTest.run),
  ("StreamRouteWriteFailTest", StreamRouteWriteFailTest.run),
  ("StreamRouteExnTest", StreamRouteExnTest.run),
  ("SceneRegistryTest", SceneRegistryTest.run),
]

// The suite currently running, so a rejection can report which one failed.
let current = ref("")

let () =
  asyncSuites
  ->Array.reduce(Promise.resolve(), (prev, (name, run)) =>
    prev->Promise.then(() => {
      current := name
      run()
    })
  )
  ->Promise.then(() => {
    Console.log("all tests passed")
    Promise.resolve()
  })
  ->Promise.catch(async e => {
    switch e {
    | JsExn(err) => Console.error(err)
    | _ => Console.error(e)
    }
    Console.error(
      "FAIL: " ++ current.contents ++ ", section \"" ++ TestKit.lastSection.contents ++ "\"",
    )
    // A failed suite can leave a server open, and the run would then hang.
    Node.Process.exit(1)
  })
  ->Promise.ignore
