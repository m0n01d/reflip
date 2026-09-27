// Tests for the pure decisions inside src/web/ScanApi.res's attempt/retry
// loop (docs/scan-ui.md "Reconnecting"; bugs B, C, D from the 288738f
// review). The loop itself is imperative (fetch, timers, an AbortController)
// and is exercised by the track's two manual browser runs instead — these
// tests cover only the decisions that were pulled out into pure functions
// so they could be tested without a network or a fake clock.

let runShouldContinue = () => {
  TestKit.section("ScanApi.shouldContinue: bug B (cancelled) and bug C (stopped must not block)")
  TestKit.check(
    "a plain, healthy run keeps going",
    ScanApi.shouldContinue(~cancelled=false, ~ended=false),
  )
  TestKit.check(
    "bug C: stopped-but-not-yet-ended still keeps going — nothing in this\n" ++
    "     function even has a `stopped` input, which is the fix: a drop\n" ++
    "     between Stop and the authoritative `end` must still reconnect",
    ScanApi.shouldContinue(~cancelled=false, ~ended=false),
  )
  TestKit.check(
    "an ended scan does not keep going",
    !ScanApi.shouldContinue(~cancelled=false, ~ended=true),
  )
  TestKit.check(
    "bug B: a cancelled run (superseded by a newer photo) does not keep going",
    !ScanApi.shouldContinue(~cancelled=true, ~ended=false),
  )
  TestKit.check(
    "cancelled and ended together still does not keep going",
    !ScanApi.shouldContinue(~cancelled=true, ~ended=true),
  )
}

let runTryNumAfter = () => {
  TestKit.section("ScanApi.tryNumAfter: bug D, the backoff resets after a good reconnect")
  TestKit.check(
    "a good response resets the try-count to 0, even after a long streak",
    ScanApi.tryNumAfter(~gotGoodResponse=true, ~tryNum=3) == 0,
  )
  TestKit.check(
    "no response at all (the connect itself failed) keeps climbing the streak",
    ScanApi.tryNumAfter(~gotGoodResponse=false, ~tryNum=3) == 3,
  )
  TestKit.check(
    "try 0 stays 0 either way",
    ScanApi.tryNumAfter(~gotGoodResponse=true, ~tryNum=0) == 0 &&
      ScanApi.tryNumAfter(~gotGoodResponse=false, ~tryNum=0) == 0,
  )
}

let run = () => {
  runShouldContinue()
  runTryNumAfter()
}
