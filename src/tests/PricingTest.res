// The price table times a fixture-shaped usage equals a hand-computed USD
// value, for two models with different cache-read multipliers.

let run = () => {
  TestKit.section("Pricing.usdCost")

  let usage: Types.usage = {
    inputTokens: 1000,
    outputTokens: 500,
    cacheReadInputTokens: 2000,
    cacheCreationInputTokens: 300,
    webSearchRequests: 2,
  }
  let expectedSonnet =
    1000.0 *. (2.0 /. 1_000_000.0) +.
    500.0 *. (10.0 /. 1_000_000.0) +.
    2000.0 *. (2.0 /. 1_000_000.0) *. 0.1 +.
    300.0 *. (2.0 /. 1_000_000.0) *. 1.25 +.
    2.0 *. 0.01
  TestKit.approx(
    "sonnet-5 cost from fixture-shaped usage",
    Pricing.usdCost(~model="claude-sonnet-5", ~usage),
    expectedSonnet,
    ~eps=1e-12,
  )

  let expectedSonnet55 =
    1000.0 *. (2.0 /. 1_000_000.0) +.
    500.0 *. (10.0 /. 1_000_000.0) +.
    2000.0 *. (2.0 /. 1_000_000.0) *. 0.05 +.
    300.0 *. (2.0 /. 1_000_000.0) *. 1.25 +.
    2.0 *. 0.01
  TestKit.approx(
    "sonnet-5.5 cost at its 0.05x cache read",
    Pricing.usdCost(~model="claude-sonnet-5-5", ~usage),
    expectedSonnet55,
    ~eps=1e-12,
  )

  let expectedHaikuShort =
    1000.0 *. (0.1 /. 1_000_000.0) +.
    500.0 *. (0.5 /. 1_000_000.0) +.
    2000.0 *. (0.1 /. 1_000_000.0) *. 0.1 +.
    300.0 *. (0.1 /. 1_000_000.0) *. 1.25 +.
    2.0 *. 0.01
  TestKit.approx(
    "haiku-5.5 short prompt on the $0.10 / $0.50 card",
    Pricing.usdCost(~model="claude-haiku-5-5", ~usage),
    expectedHaikuShort,
    ~eps=1e-12,
  )

  let longUsage: Types.usage = {
    inputTokens: 90_000,
    outputTokens: 500,
    cacheReadInputTokens: 20_000,
    cacheCreationInputTokens: 0,
    webSearchRequests: 0,
  }
  let expectedHaikuLong =
    90_000.0 *. (0.5 /. 1_000_000.0) +.
    500.0 *. (2.5 /. 1_000_000.0) +.
    20_000.0 *. (0.5 /. 1_000_000.0) *. 0.1
  TestKit.approx(
    "haiku-5.5 prompt over 100K on the $0.50 / $2.50 card",
    Pricing.usdCost(~model="claude-haiku-5-5", ~usage=longUsage),
    expectedHaikuLong,
    ~eps=1e-12,
  )

  let opusUsage: Types.usage = {
    inputTokens: 100,
    outputTokens: 100,
    cacheReadInputTokens: 100,
    cacheCreationInputTokens: 0,
    webSearchRequests: 0,
  }
  let expectedOpus =
    100.0 *. (4.0 /. 1_000_000.0) +.
    100.0 *. (20.0 /. 1_000_000.0) +.
    100.0 *. (4.0 /. 1_000_000.0) *. 0.05
  TestKit.approx(
    "opus-5.5 cache read at its 0.05x multiplier",
    Pricing.usdCost(~model="claude-opus-5-5", ~usage=opusUsage),
    expectedOpus,
    ~eps=1e-12,
  )

  TestKit.check(
    "unknown model costs 0.0, never crashes",
    Pricing.usdCost(~model="not-a-real-model", ~usage) == 0.0,
  )
}
