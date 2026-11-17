// Claude model pricing, per reflip's CLAUDE.md "Claude API facts" table —
// checked 2026-11-17 against platform.claude.com/docs/en/about-claude/pricing
// and the claude-api skill.

// Prices that apply when a prompt is longer than `overTokens`.
type longPrompt = {overTokens: int, inputPerMTok: float, outputPerMTok: float}

type priceRow = {
  inputPerMTok: float,
  outputPerMTok: float,
  cacheReadMultiplier: float,
  webSearchToolType: string,
  longPrompt: option<longPrompt>,
}

let defaultModel = Shared.modelId(Shared.defaultModel)

let table: dict<priceRow> = Dict.fromArray([
  (
    "claude-opus-5-5",
    {
      inputPerMTok: 4.0,
      outputPerMTok: 20.0,
      cacheReadMultiplier: 0.05,
      webSearchToolType: "web_search_20260209",
      longPrompt: None,
    },
  ),
  (
    "claude-sonnet-5-5",
    {
      inputPerMTok: 2.0,
      outputPerMTok: 10.0,
      cacheReadMultiplier: 0.05,
      webSearchToolType: "web_search_20260209",
      longPrompt: None,
    },
  ),
  (
    "claude-haiku-5-5",
    {
      inputPerMTok: 0.1,
      outputPerMTok: 0.5,
      cacheReadMultiplier: 0.1,
      webSearchToolType: "web_search_20260209",
      longPrompt: Some({overTokens: 100_000, inputPerMTok: 0.5, outputPerMTok: 2.5}),
    },
  ),
  // The next two rows price scenes logged before 2026-11-17.
  (
    "claude-sonnet-5",
    {
      inputPerMTok: 2.0,
      outputPerMTok: 10.0,
      cacheReadMultiplier: 0.1,
      webSearchToolType: "web_search_20260209",
      longPrompt: None,
    },
  ),
  (
    "claude-haiku-4-5",
    {
      inputPerMTok: 1.0,
      outputPerMTok: 5.0,
      cacheReadMultiplier: 0.1,
      webSearchToolType: "web_search_20250305",
      longPrompt: None,
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
      let promptTokens =
        usage.inputTokens + usage.cacheReadInputTokens + usage.cacheCreationInputTokens
      let (inPrice, outPrice) = switch row.longPrompt {
      | Some(lp) if promptTokens > lp.overTokens => (lp.inputPerMTok, lp.outputPerMTok)
      | _ => (row.inputPerMTok, row.outputPerMTok)
      }
      let perTokIn = inPrice /. 1_000_000.0
      let perTokOut = outPrice /. 1_000_000.0
      Int.toFloat(usage.inputTokens) *. perTokIn +.
      Int.toFloat(usage.outputTokens) *. perTokOut +.
      Int.toFloat(usage.cacheReadInputTokens) *. perTokIn *. row.cacheReadMultiplier +.
      Int.toFloat(usage.cacheCreationInputTokens) *. perTokIn *. cacheWriteMultiplier +.
      Int.toFloat(usage.webSearchRequests) *. webSearchFlatUsd
    }
  }
