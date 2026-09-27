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

  TestKit.section("Profit.netText, profitText, lineText, isLoss, partsText")

  // Case 1: $20 to $30, medium, no tag.
  let c1 = Profit.estimate(~lowUsd=20.0, ~highUsd=30.0, ~shipClass=Profit.Medium, ~tagPriceUsd=None)
  TestKit.check("netText: case 1 range", Profit.netText(c1) == "Net $5 to $14")
  TestKit.check("profitText: case 1 with no tag is None", Profit.profitText(c1) == None)
  TestKit.check(
    "lineText: case 1 with no tag falls back to netText",
    Profit.lineText(c1) == "Net $5 to $14",
  )
  TestKit.check("isLoss: case 1 with no tag is not a loss", !Profit.isLoss(c1))

  // Case 1 with a $4 tag: profit = net - tag at each end.
  let c1Tag4 = Profit.estimate(
    ~lowUsd=20.0,
    ~highUsd=30.0,
    ~shipClass=Profit.Medium,
    ~tagPriceUsd=Some(4.0),
  )
  TestKit.check(
    "profitText: case 1 with a $4 tag",
    Profit.profitText(c1Tag4) == Some("Profit $1 to $10 at the $4 tag"),
  )
  TestKit.check(
    "lineText: case 1 with a $4 tag uses profitText",
    Profit.lineText(c1Tag4) == "Profit $1 to $10 at the $4 tag",
  )
  TestKit.check("isLoss: case 1 with a $4 tag is not a loss", !Profit.isLoss(c1Tag4))

  // Case 1 with a $0.50 tag: the tag shows cents because it is not whole.
  let c1TagHalf = Profit.estimate(
    ~lowUsd=20.0,
    ~highUsd=30.0,
    ~shipClass=Profit.Medium,
    ~tagPriceUsd=Some(0.5),
  )
  TestKit.check(
    "profitText: a non-whole tag shows cents",
    switch Profit.profitText(c1TagHalf) {
    | Some(t) => String.includes(t, "at the $0.50 tag")
    | None => false
    },
  )

  // Case 2: an $8 item in class small, low = high (one price, not a range).
  // It loses money on eBay even with no tag.
  let c2 = Profit.estimate(~lowUsd=8.0, ~highUsd=8.0, ~shipClass=Profit.Small, ~tagPriceUsd=None)
  TestKit.check("netText: case 2 is a single negative value", Profit.netText(c2) == "Net -$1")
  TestKit.check("isLoss: case 2 is a loss", Profit.isLoss(c2))

  // partsText: the parts at the midpoint. Fee and postage show cents.
  TestKit.check(
    "partsText: case 1 names the postage in cents with its class",
    String.includes(Profit.partsText(c1, ~midUsd=25.0), "Postage $11.57 (medium)"),
  )
  TestKit.check(
    "partsText: a tag price adds a Tag part",
    String.includes(Profit.partsText(c1Tag4, ~midUsd=25.0), "Tag $4"),
  )
}
