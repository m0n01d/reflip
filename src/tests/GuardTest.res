// Guard: build the Claude request body in fixture mode, serialize it, and
// make sure it contains no title and no price from the eBay fixtures.
// CLAUDE.md hard design rule 1 — eBay numbers never reach the model.

let run = () => {
  TestKit.section("Guard: eBay numbers never reach the model")

  let fixturesDir = Node.Path.join([Node.Process.cwd(), "tests/fixtures"])
  let ebayJson = EbayClient.searchFixture(fixturesDir, 0)
  let items = Json.arrayField(ebayJson, "itemSummaries")->Option.getOr([])
  let titles = Array.filterMap(items, item => Json.stringField(item, "title"))
  let prices = Array.filterMap(items, item =>
    Json.field(item, "price")->Option.flatMap(p => Json.stringField(p, "value"))
  )

  TestKit.check("fixture actually has titles to check against", Array.length(titles) > 0)
  TestKit.check("fixture actually has prices to check against", Array.length(prices) > 0)

  let requestJson = ClaudeClient.buildRequestBody(
    ~model="claude-sonnet-5",
    ~imageBase64="ZmFrZQ==",
    ~structuredOutput=true,
  )
  let serialized = JSON.stringify(requestJson)

  Array.forEach(titles, title =>
    TestKit.check(
      "request body excludes eBay title \"" ++ title ++ "\"",
      !String.includes(serialized, title),
    )
  )
  Array.forEach(prices, price =>
    TestKit.check(
      "request body excludes eBay price " ++ price,
      !String.includes(serialized, price),
    )
  )
}
