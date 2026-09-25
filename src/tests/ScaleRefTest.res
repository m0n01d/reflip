// docs/spec-scale-ref.md, "Tests" section, items 1, 2 and 4: the prompt and
// schema shape (checked directly against SystemPrompt.res, not a fixture),
// the prompt version bump, and a hand-built encode/decode round trip for
// Types.sceneReply's new size and quarterSeen fields.

let requiredNames = (schema: JSON.t): array<string> =>
  Json.arrayField(schema, "required")
  ->Option.map(arr => Array.filterMap(arr, JSON.Decode.string))
  ->Option.getOr([])

let run = () => {
  TestKit.section("ScaleRef: prompts and schemas")

  TestKit.check(
    "the scene prompt names the quarter's size",
    String.includes(SystemPrompt.text, "24.26 mm"),
  )
  TestKit.check(
    "the haul prompt names the quarter's size",
    String.includes(SystemPrompt.haulPrompt(~gemMinUsd=20.0), "24.26 mm"),
  )

  TestKit.check(
    "the scene item schema requires size",
    Array.some(requiredNames(SystemPrompt.itemSchema), n => n == "size"),
  )
  TestKit.check(
    "the haul item schema requires size",
    Array.some(requiredNames(SystemPrompt.haulItemSchema), n => n == "size"),
  )

  TestKit.check(
    "the scene response schema requires quarterSeen",
    Array.some(requiredNames(SystemPrompt.responseSchema), n => n == "quarterSeen"),
  )
  TestKit.check(
    "the haul response schema does not require quarterSeen",
    !Array.some(requiredNames(SystemPrompt.haulResponseSchema), n => n == "quarterSeen"),
  )

  TestKit.check("the scene prompt version is scene-2", SystemPrompt.promptVersion == "scene-2")
  TestKit.check("the haul prompt version is haul-2", SystemPrompt.haulPromptVersion == "haul-2")

  TestKit.section("ScaleRef: encodeSceneReply / decodeSceneReply round trip")

  let reply: Types.sceneReply = {
    Types.sceneId: "scene-roundtrip",
    model: "claude-sonnet-5",
    fixture: true,
    outputPath: "/tmp/scale-ref-roundtrip.json",
    items: [
      {
        Types.name: "Dutch oven",
        query: "vintage Dutch oven 5.5 qt",
        confidence: 0.6,
        estimateLowUsd: 20.0,
        estimateHighUsd: 45.0,
        basis: "Common size, steady demand",
        sources: [],
        ebay: None,
        soldSearchUrl: "https://www.ebay.com/sch/i.html?_nkw=dutch+oven&LH_Sold=1",
        size: "5.5 qt",
        box: None,
      },
    ],
    imageWidth: 800,
    imageHeight: 600,
    timing: {Types.serverMs: 1.0, claudeMs: 2.0, ebayMs: 3.0},
    cost: {
      Types.usd: 0.01,
      inputTokens: 10,
      outputTokens: 5,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
      webSearches: 0,
    },
    ebayNote: None,
    quarterSeen: true,
  }

  let json = Types.encodeSceneReply(reply)
  switch Shared.decodeSceneReply(json) {
  | Error(msg) => TestKit.check("the round-tripped reply decodes (" ++ msg ++ ")", false)
  | Ok(decoded) => {
      TestKit.check("quarterSeen survives the round trip", decoded.quarterSeen == true)
      TestKit.check(
        "an item's size survives the round trip",
        Array.get(decoded.items, 0)->Option.map(i => i.size) == Some("5.5 qt"),
      )
    }
  }
}
