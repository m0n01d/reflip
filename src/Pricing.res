// Claude model pricing, per reflip's CLAUDE.md "Claude API facts" table —
// checked 2026-09-24 against platform.claude.com/docs/en/about-claude/pricing
// and the claude-api skill.

type priceRow = {
  inputPerMTok: float,
  outputPerMTok: float,
  cacheReadMultiplier: float,
  webSearchToolType: string,
}

let defaultModel = "claude-sonnet-5"

let table: dict<priceRow> = Dict.fromArray([
  (
    "claude-opus-5-5",
    {
      inputPerMTok: 4.0,
      outputPerMTok: 20.0,
      cacheReadMultiplier: 0.05,
      webSearchToolType: "web_search_20260209",
    },
  ),
  (
    "claude-sonnet-5",
    {
      inputPerMTok: 2.0,
      outputPerMTok: 10.0,
      cacheReadMultiplier: 0.1,
      webSearchToolType: "web_search_20260209",
    },
  ),
  (
    "claude-haiku-4-5",
    {
      inputPerMTok: 1.0,
      outputPerMTok: 5.0,
      cacheReadMultiplier: 0.1,
      webSearchToolType: "web_search_20250305",
    },
  ),
])

let rowFor = (model: string): option<priceRow> => Dict.get(table, model)

// A 5-minute cache write costs 1.25x the input price, on every model here.
let cacheWriteMultiplier = 1.25

// Flat per-search fee. Its result text bills separately, as input tokens
// already counted in `usage.inputTokens`.
let webSearchFlatUsd = 0.01

let usdCost = (~model: string, ~usage: Types.usage): float =>
  switch rowFor(model) {
  | None => 0.0
  | Some(row) => {
      let perTokIn = row.inputPerMTok /. 1_000_000.0
      let perTokOut = row.outputPerMTok /. 1_000_000.0
      Int.toFloat(usage.inputTokens) *. perTokIn +.
      Int.toFloat(usage.outputTokens) *. perTokOut +.
      Int.toFloat(usage.cacheReadInputTokens) *. perTokIn *. row.cacheReadMultiplier +.
      Int.toFloat(usage.cacheCreationInputTokens) *. perTokIn *. cacheWriteMultiplier +.
      Int.toFloat(usage.webSearchRequests) *. webSearchFlatUsd
    }
  }
