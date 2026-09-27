// Profit.res's fee, net and estimate math, against the two cases of
// docs/spec-profit.md "The math", at a tolerance of $0.001.

let run = () => {
  TestKit.section("Profit.fee and Profit.net")

  // Case 1: a range of $20 to $30, class medium ($11.57), paid $4.
  TestKit.approx("fee at $20", Profit.fee(20.0), 3.324, ~eps=0.001)
  TestKit.approx("fee at $25", Profit.fee(25.0), 4.055, ~eps=0.001)
  TestKit.approx("fee at $30", Profit.fee(30.0), 4.786, ~eps=0.001)

  TestKit.approx("net at $20, medium", Profit.net(20.0, Profit.Medium), 5.106, ~eps=0.001)
  TestKit.approx("net at $25, medium", Profit.net(25.0, Profit.Medium), 9.375, ~eps=0.001)
  TestKit.approx("net at $30, medium", Profit.net(30.0, Profit.Medium), 13.644, ~eps=0.001)

  let paidUsd = 4.0
  TestKit.approx(
    "profit at $20, medium, paid $4",
    Profit.net(20.0, Profit.Medium) -. paidUsd,
    1.106,
    ~eps=0.001,
  )
  TestKit.approx(
    "profit at $25, medium, paid $4",
    Profit.net(25.0, Profit.Medium) -. paidUsd,
    5.375,
    ~eps=0.001,
  )
  TestKit.approx(
    "profit at $30, medium, paid $4",
    Profit.net(30.0, Profit.Medium) -. paidUsd,
    9.644,
    ~eps=0.001,
  )

  TestKit.section("Profit.estimate")

  let e1 = Profit.estimate(
    ~lowUsd=20.0,
    ~highUsd=30.0,
    ~shipClass=Profit.Medium,
    ~tagPriceUsd=None,
  )
  TestKit.check("estimate: shipClass stays medium", e1.shipClass == Profit.Medium)
  TestKit.approx("estimate: postageUsd, medium", e1.postageUsd, 11.57, ~eps=0.001)
  TestKit.approx("estimate: feeMidUsd", e1.feeMidUsd, 4.055, ~eps=0.001)
  TestKit.approx("estimate: netLowUsd", e1.netLowUsd, 5.106, ~eps=0.001)
  TestKit.approx("estimate: netMidUsd", e1.netMidUsd, 9.375, ~eps=0.001)
  TestKit.approx("estimate: netHighUsd", e1.netHighUsd, 13.644, ~eps=0.001)
  TestKit.check("estimate: tagPriceUsd stays None", e1.tagPriceUsd == None)

  let e2 = Profit.estimate(
    ~lowUsd=8.0,
    ~highUsd=8.0,
    ~shipClass=Profit.Small,
    ~tagPriceUsd=Some(4.0),
  )
  TestKit.check("estimate: tagPriceUsd carries the tag price", e2.tagPriceUsd == Some(4.0))

  // Case 2: an $8 item in class small ($7.69). It loses money on eBay.
  TestKit.approx("order total at $8", 8.0 *. 1.075, 8.60, ~eps=0.001)
  TestKit.approx("fee at $8", Profit.fee(8.0), 1.470, ~eps=0.001)
  TestKit.approx("net at $8, small", Profit.net(8.0, Profit.Small), -1.160, ~eps=0.001)

  TestKit.section("Profit.toString and Profit.fromString")

  TestKit.check(
    "small round trip",
    Profit.fromString(Profit.toString(Profit.Small)) == Some(Profit.Small),
  )
  TestKit.check(
    "medium round trip",
    Profit.fromString(Profit.toString(Profit.Medium)) == Some(Profit.Medium),
  )
  TestKit.check(
    "large round trip",
    Profit.fromString(Profit.toString(Profit.Large)) == Some(Profit.Large),
  )
  TestKit.check(
    "pickup round trip",
    Profit.fromString(Profit.toString(Profit.Pickup)) == Some(Profit.Pickup),
  )
  TestKit.check("unknown string gives None", Profit.fromString("bogus") == None)
}
