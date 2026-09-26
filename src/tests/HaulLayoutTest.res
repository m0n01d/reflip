// HaulLayout: no DOM, so this runs under Node like BoxLayoutTest.res.
// Expected numbers for cropOf/thumbOf/pinsOn/barOf are hand-computed
// (Python, double precision, same math as the ReScript) against
// docs/design/haul-ui/Main.dc.html and, for barOf, against
// docs/design/haul-ui/EbayBlock.dc.html's literal rendered pixel values.

let run = () => {
  TestKit.section("HaulLayout")

  // -- tallyOf -------------------------------------------------------------
  let counts: Types.haulCounts = {queued: 3, running: 1, valued: 5, failed: 2}
  let running = HaulLayout.tallyOf(counts, 2, false)
  TestKit.check("running: valuing is queued + running", running.valuing == 4)
  TestKit.check("running: notValued is 0", running.notValued == 0)
  TestKit.check("running: onPhone is the queue length", running.onPhone == 2)
  TestKit.check("running: valued and failed pass through", running.valued == 5 && running.failed == 2)

  let stopped = HaulLayout.tallyOf(counts, 2, true)
  TestKit.check("stopped: valuing is running alone", stopped.valuing == 1)
  TestKit.check("stopped: notValued is the queued count", stopped.notValued == 3)

  // -- legendOf --------------------------------------------------------------
  let base: HaulLayout.tileCounts = {valued: 4, valuing: 2, onPhone: 1, notValued: 0, failed: 0}
  TestKit.check(
    "legend with neither notValued nor failed",
    HaulLayout.legendOf(base) == "4 valued · 2 valuing · 1 on phone",
  )
  TestKit.check(
    "legend with notValued only",
    HaulLayout.legendOf({...base, notValued: 3}) ==
      "4 valued · 2 valuing · 1 on phone · 3 not valued",
  )
  TestKit.check(
    "legend with failed only",
    HaulLayout.legendOf({...base, failed: 2}) == "4 valued · 2 valuing · 1 on phone · 2 failed",
  )
  TestKit.check(
    "legend with both notValued and failed, in that order",
    HaulLayout.legendOf({...base, notValued: 3, failed: 2}) ==
      "4 valued · 2 valuing · 1 on phone · 3 not valued · 2 failed",
  )

  // -- budgetFillPct ---------------------------------------------------------
  TestKit.approx("budget fill: half spent", HaulLayout.budgetFillPct(5.0, 10.0), 0.5, ~eps=0.001)
  TestKit.approx(
    "budget fill: over the cap clamps to 1.0",
    HaulLayout.budgetFillPct(12.0, 10.0),
    1.0,
    ~eps=0.001,
  )
  TestKit.approx(
    "budget fill: a zero max is 0.0, never a division error",
    HaulLayout.budgetFillPct(5.0, 0.0),
    0.0,
    ~eps=0.001,
  )

  // -- notchPositions ----------------------------------------------------
  TestKit.check(
    "notchPositions: valued <= 1 gives no notches",
    HaulLayout.notchPositions(~costUsd=5.0, ~maxUsd=10.0, ~valued=1) == [],
  )
  let notches3 = HaulLayout.notchPositions(~costUsd=6.0, ~maxUsd=10.0, ~valued=3)
  TestKit.check("notchPositions: valued=3 gives 2 notches", Array.length(notches3) == 2)
  TestKit.approx(
    "notchPositions: first notch at 1/3 of cost over max",
    Array.getUnsafe(notches3, 0),
    6.0 *. 1.0 /. 3.0 /. 10.0,
    ~eps=0.001,
  )
  TestKit.approx(
    "notchPositions: second notch clamps to the max",
    Array.getUnsafe(notches3, 1),
    Math.min(6.0 *. 2.0 /. 3.0, 10.0) /. 10.0,
    ~eps=0.001,
  )

  // -- lastN / finishingText ------------------------------------------------
  TestKit.check("lastN(1) is singular", HaulLayout.lastN(1) == "the last photo")
  TestKit.check("lastN(3) is plural", HaulLayout.lastN(3) == "the last 3 photos")
  TestKit.check(
    "finishingText: photos still on the phone",
    HaulLayout.finishingText(~onPhone=2, ~valuing=1) == "Sending the last 2 photos…",
  )
  TestKit.check(
    "finishingText: nothing on the phone, still valuing",
    HaulLayout.finishingText(~onPhone=0, ~valuing=1) ==
      "Done. Valuing the last photo, then the digest goes out.",
  )
  TestKit.check(
    "finishingText: nothing left to value",
    HaulLayout.finishingText(~onPhone=0, ~valuing=0) == "Done. Sending the digest…",
  )

  // -- offlineText -----------------------------------------------------------
  TestKit.check(
    "offlineText: singular",
    HaulLayout.offlineText(1) == "Can’t reach reflip. 1 photo is safe on the phone and sends on its own.",
  )
  TestKit.check(
    "offlineText: plural",
    HaulLayout.offlineText(3) ==
      "Can’t reach reflip. 3 photos are safe on the phone and send on their own.",
  )

  // -- cropOf ------------------------------------------------------------
  // A square box needing the 460px floor, wider than tall after clamping
  // (w0=460 > h0=130, and 460/130 > frameAspect, so the `else` branch
  // picks h = w / frameAspect). Hand-computed in Python with the same
  // formula.
  let wideBox: Types.box = {x1: 100, y1: 100, x2: 200, y2: 200}
  let c1 = HaulLayout.cropOf(wideBox, ~imageWidth=1000, ~imageHeight=1000)
  TestKit.approx("cropOf wide: x0", c1.x0, 0.0, ~eps=0.05)
  TestKit.approx("cropOf wide: y0", c1.y0, 31.7877, ~eps=0.05)
  TestKit.approx("cropOf wide: k", c1.k, 0.778261, ~eps=0.0005)
  TestKit.approx("cropOf wide: imgWidthPx", c1.imgWidthPx, 778.261, ~eps=0.05)
  TestKit.approx("cropOf wide: boxLeftPx", c1.boxLeftPx, 77.826, ~eps=0.05)
  TestKit.approx("cropOf wide: boxWidthPx", c1.boxWidthPx, 77.826, ~eps=0.05)

  // A tall, narrow box: w0/h0 < frameAspect, so the `if` branch picks
  // w = h * frameAspect instead.
  let tallBox: Types.box = {x1: 100, y1: 50, x2: 150, y2: 350}
  let c2 = HaulLayout.cropOf(tallBox, ~imageWidth=1000, ~imageHeight=1000)
  TestKit.approx("cropOf tall: y0", c2.y0, 5.0, ~eps=0.05)
  TestKit.approx("cropOf tall: k", c2.k, 0.471795, ~eps=0.0005)
  TestKit.approx("cropOf tall: boxHeightPx", c2.boxHeightPx, 141.538, ~eps=0.05)

  // -- thumbOf -----------------------------------------------------------
  let t1 = HaulLayout.thumbOf(wideBox, ~imageWidth=1000, ~imageHeight=1000)
  TestKit.approx("thumbOf: imgLeftPx", t1.imgLeftPx, -33.0, ~eps=0.05)
  TestKit.approx("thumbOf: imgWidthPx", t1.imgWidthPx, 366.667, ~eps=0.05)

  // side clamped by imageHeight (a very wide box in a short photo).
  let wideFlatBox: Types.box = {x1: 0, y1: 0, x2: 2000, y2: 2000}
  let t2 = HaulLayout.thumbOf(wideFlatBox, ~imageWidth=1000, ~imageHeight=500)
  TestKit.approx("thumbOf clamped: imgLeftPx", t2.imgLeftPx, -44.0, ~eps=0.05)
  TestKit.approx("thumbOf clamped: imgTopPx", t2.imgTopPx, 0.0, ~eps=0.05)
  TestKit.approx("thumbOf clamped: imgWidthPx", t2.imgWidthPx, 88.0, ~eps=0.05)
  TestKit.approx("thumbOf clamped: imgHeightPx", t2.imgHeightPx, 44.0, ~eps=0.05)

  // -- pinsOn --------------------------------------------------------------
  let crop = HaulLayout.cropOf(wideBox, ~imageWidth=1000, ~imageHeight=1000)
  // Another gem with the same box (a stand-in for "close to the open
  // gem") lands inside the crop window.
  let nearPins = HaulLayout.pinsOn(~crop, ~others=[(2, wideBox)])
  TestKit.check("pinsOn: a nearby gem is kept", Array.length(nearPins) == 1)
  switch Array.get(nearPins, 0) {
  | Some(p) =>
    TestKit.check("pinsOn: keeps the caller's rank number", p.num == "2")
    TestKit.approx("pinsOn: leftPx", p.leftPx, 116.739 -. 13.0, ~eps=0.05)
    TestKit.approx("pinsOn: topPx", p.topPx, 92.0 -. 13.0, ~eps=0.05)
    TestKit.check("pinsOn: rotateDeg matches tilt(2)", p.rotateDeg == HaulLayout.tilt(2))
  | None => TestKit.check("pinsOn: a nearby gem is kept", false)
  }
  // A gem far across the photo falls outside the crop window and is
  // dropped.
  let farBox: Types.box = {x1: 880, y1: 880, x2: 920, y2: 920}
  let farPins = HaulLayout.pinsOn(~crop, ~others=[(3, farBox)])
  TestKit.check("pinsOn: a far-away gem is dropped", Array.length(farPins) == 0)

  // -- tilt ------------------------------------------------------------------
  TestKit.check("tilt(3) matches the ported formula", HaulLayout.tilt(3) == mod(3 * 37, 17) - 8)

  // -- barOf, against EbayBlock.dc.html's literal rendered pixels ---------
  // Gem 3 fixture: eBay $28.50-89.99 (median $61.50), Claude's own
  // estimate $20-42.
  let ebay3: Types.ebayStats = {
    count: 6,
    minUsd: 28.50,
    p25Usd: 0.0,
    medianUsd: 61.50,
    p75Usd: 0.0,
    maxUsd: 89.99,
  }
  let bar3 = HaulLayout.barOf(
    ~ebay=ebay3,
    ~lowUsd=20.0,
    ~highUsd=42.0,
    ~labMin="$28.50",
    ~labMed="$61.50",
    ~labMax="$89.99",
    ~bandText="Claude’s $20–42",
  )
  // EbayBlock.dc.html: "left: 20px" / "174.7px" / "288.4px" for the three
  // labels, "39.8px" / "288.2px" for the ink line, "39.1px" / "327.3px"
  // for the ticks, "193px" for the median tick, "0px" / "103.1px" for the
  // band, "2.1px" for the band text. Allow 0.5px for px()'s own rounding.
  TestKit.approx("barOf gem3: labMinLeftPx", bar3.labMinLeftPx, 20.0, ~eps=0.5)
  TestKit.approx("barOf gem3: labMedLeftPx", bar3.labMedLeftPx, 174.7, ~eps=0.5)
  TestKit.approx("barOf gem3: labMaxLeftPx", bar3.labMaxLeftPx, 288.4, ~eps=0.5)
  TestKit.approx("barOf gem3: lineLeftPx", bar3.lineLeftPx, 39.8, ~eps=0.5)
  TestKit.approx("barOf gem3: lineWidthPx", bar3.lineWidthPx, 288.2, ~eps=0.5)
  TestKit.approx("barOf gem3: tickMinLeftPx", bar3.tickMinLeftPx, 39.1, ~eps=0.5)
  TestKit.approx("barOf gem3: tickMaxLeftPx", bar3.tickMaxLeftPx, 327.3, ~eps=0.5)
  TestKit.approx("barOf gem3: medLeftPx", bar3.medLeftPx, 193.0, ~eps=0.5)
  TestKit.approx("barOf gem3: bandLeftPx", bar3.bandLeftPx, 0.0, ~eps=0.5)
  TestKit.approx("barOf gem3: bandWidthPx", bar3.bandWidthPx, 103.1, ~eps=0.5)
  TestKit.approx("barOf gem3: bandTextLeftPx", bar3.bandTextLeftPx, 2.1, ~eps=0.5)

  // Gem 4 fixture: eBay $15.00-31.00 (median $22.00), Claude's estimate
  // $15-30 — the eBay range fully contains Claude's range here.
  let ebay4: Types.ebayStats = {
    count: 5,
    minUsd: 15.00,
    p25Usd: 0.0,
    medianUsd: 22.00,
    p75Usd: 0.0,
    maxUsd: 31.00,
  }
  let bar4 = HaulLayout.barOf(
    ~ebay=ebay4,
    ~lowUsd=15.0,
    ~highUsd=30.0,
    ~labMin="$15.00",
    ~labMed="$22.00",
    ~labMax="$31.00",
    ~bandText="Claude’s $15–30",
  )
  TestKit.approx("barOf gem4: labMinLeftPx", bar4.labMinLeftPx, 0.0, ~eps=0.5)
  TestKit.approx("barOf gem4: labMedLeftPx", bar4.labMedLeftPx, 123.7, ~eps=0.5)
  TestKit.approx("barOf gem4: labMaxLeftPx", bar4.labMaxLeftPx, 288.4, ~eps=0.5)
  TestKit.approx("barOf gem4: lineLeftPx", bar4.lineLeftPx, 0.0, ~eps=0.5)
  TestKit.approx("barOf gem4: lineWidthPx", bar4.lineWidthPx, 328.0, ~eps=0.5)
  TestKit.approx("barOf gem4: bandWidthPx", bar4.bandWidthPx, 307.5, ~eps=0.5)
  TestKit.approx("barOf gem4: bandTextLeftPx", bar4.bandTextLeftPx, 104.25, ~eps=0.5)

  // -- pxStr -----------------------------------------------------------------
  TestKit.check("pxStr rounds to one decimal", HaulLayout.pxStr(39.8342) == "39.8px")
}
