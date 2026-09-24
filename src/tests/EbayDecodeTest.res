// eBay decode: the fixture gives the expected stats, and a response with no
// itemSummaries decodes to None rather than crashing.

let run = () => {
  TestKit.section("EbayClient.decodeStats")

  let fixturesDir = Node.Path.join([Node.Process.cwd(), "tests/fixtures"])
  let json0 = EbayClient.searchFixture(fixturesDir, 0)
  switch EbayClient.decodeStats(json0) {
  | Some(stats) => {
      TestKit.check("ebay-search-0 has at least one item", stats.count >= 1)
      TestKit.check("ebay-search-0 min <= median", stats.minUsd <= stats.medianUsd)
      TestKit.check("ebay-search-0 median <= max", stats.medianUsd <= stats.maxUsd)
    }
  | None => TestKit.check("ebay-search-0 decodes to Some", false)
  }

  TestKit.check(
    "no itemSummaries is None",
    EbayClient.decodeStats(Json.obj([("total", Json.num(0.0))])) == None,
  )
}
