// Our own prompt text and structured-output schema for the scene endpoint.
// This is original text: Flip Scout reuses ideas from wesbos/yard-sale, not
// its code or its prompt text (see reflip's CLAUDE.md, Origin).

let text = `You are the valuation brain for Flip Scout, a personal resale scanner.
You will receive one photo of items on a table, shelf, or floor.

Find every distinct sellable item in the photo. Skip clutter, trash, and
anything that is not resellable.

For each item, report:
- name: a short name for the item
- maker: the maker or brand if you can see it, else an empty string
- query: a search query of 3 to 8 words a reseller would type into eBay
- estimateLowUsd and estimateHighUsd: a used resale range in US dollars
- basis: one line on why you estimated that range
- confidence: a number from 0 to 1
- sources: the source URLs you used, or an empty array if you used none
- box: [x1, y1, x2, y2], the top-left and bottom-right corners of the item
  in the photo, in integer pixel coordinates. x1 and y1 are the pixel
  position of the top-left corner. x2 and y2 are the pixel position of the
  bottom-right corner. The photo's width and height in pixels are given
  below.

Use the web_search tool only when you are unsure of an item's value, and at
most 3 times for this photo. Never search ebay.com; it is blocked there.
Prefer retailer and enthusiast sites for comparable prices.

Reply with JSON only, shaped as {"items": [...]}. Do not add any commentary
outside that JSON object.`

let itemSchema: JSON.t = Json.obj([
  ("type", Json.str("object")),
  (
    "properties",
    Json.obj([
      ("name", Json.obj([("type", Json.str("string"))])),
      ("maker", Json.obj([("type", Json.str("string"))])),
      ("query", Json.obj([("type", Json.str("string"))])),
      ("estimateLowUsd", Json.obj([("type", Json.str("number"))])),
      ("estimateHighUsd", Json.obj([("type", Json.str("number"))])),
      ("basis", Json.obj([("type", Json.str("string"))])),
      ("confidence", Json.obj([("type", Json.str("number"))])),
      (
        "sources",
        Json.obj([
          ("type", Json.str("array")),
          ("items", Json.obj([("type", Json.str("string"))])),
        ]),
      ),
      (
        "box",
        Json.obj([
          ("type", Json.str("array")),
          ("items", Json.obj([("type", Json.str("integer"))])),
        ]),
      ),
    ]),
  ),
  (
    "required",
    Json.arr([
      Json.str("name"),
      Json.str("maker"),
      Json.str("query"),
      Json.str("estimateLowUsd"),
      Json.str("estimateHighUsd"),
      Json.str("basis"),
      Json.str("confidence"),
      Json.str("sources"),
      Json.str("box"),
    ]),
  ),
  ("additionalProperties", Json.boolJ(false)),
])

let responseSchema: JSON.t = Json.obj([
  ("type", Json.str("object")),
  (
    "properties",
    Json.obj([("items", Json.obj([("type", Json.str("array")), ("items", itemSchema)]))]),
  ),
  ("required", Json.arr([Json.str("items")])),
  ("additionalProperties", Json.boolJ(false)),
])

// output_config.format shape, per the claude-api skill (checked 2026-09-24):
// { type: "json_schema", schema: {...} }.
let outputFormat: JSON.t = Json.obj([
  ("type", Json.str("json_schema")),
  ("schema", responseSchema),
])

// Stamped on every find row (Store.find.promptVersion), so a later prompt
// change never scrambles history. POST /api/scene uses this one; haul mode
// uses haulPromptVersion below.
let promptVersion = "scene-1"

// Haul mode's own words: only list items worth the trip to sell, name
// where each one sits in the photo, and count the rest instead of
// describing them. Not yard-sale's prompt (see reflip's CLAUDE.md, Origin).
let haulPrompt = (~gemMinUsd: float): string => {
  let threshold = "$" ++ Float.toString(gemMinUsd)
  `You are the valuation brain for Flip Scout, a personal resale scanner
running in haul mode. You will receive one photo from a batch of photos of
items to sell.

List only the items that could resell for ${threshold} or more, on the high
end of your estimate. Skip clutter, trash, and anything that is not
resellable, and skip any item worth less than that on the high end too —
just count it instead.

For each listed item, report:
- name: a short name for the item
- maker: the maker or brand if you can see it, else an empty string
- query: a search query of 3 to 8 words a reseller would type into eBay
- estimateLowUsd and estimateHighUsd: a used resale range in US dollars
- basis: one line on why you estimated that range
- confidence: a number from 0 to 1
- sources: the source URLs you used, or an empty array if you used none
- where: a short phrase that locates the item in the photo, such as "top
  shelf, fourth spine from the left, red"

Count every other visible, resellable item that you did not list above,
and report that count as otherCount.

Use the web_search tool only when you are unsure of an item's value, and at
most 3 times for this photo. Never search ebay.com; it is blocked there.
Prefer retailer and enthusiast sites for comparable prices.

Reply with JSON only, shaped as {"items": [...], "otherCount": N}. Do not
add any commentary outside that JSON object.`
}

// Same shape as itemSchema, plus the required `where` field.
let haulItemSchema: JSON.t = Json.obj([
  ("type", Json.str("object")),
  (
    "properties",
    Json.obj([
      ("name", Json.obj([("type", Json.str("string"))])),
      ("maker", Json.obj([("type", Json.str("string"))])),
      ("query", Json.obj([("type", Json.str("string"))])),
      ("estimateLowUsd", Json.obj([("type", Json.str("number"))])),
      ("estimateHighUsd", Json.obj([("type", Json.str("number"))])),
      ("basis", Json.obj([("type", Json.str("string"))])),
      ("confidence", Json.obj([("type", Json.str("number"))])),
      (
        "sources",
        Json.obj([
          ("type", Json.str("array")),
          ("items", Json.obj([("type", Json.str("string"))])),
        ]),
      ),
      ("where", Json.obj([("type", Json.str("string"))])),
    ]),
  ),
  (
    "required",
    Json.arr([
      Json.str("name"),
      Json.str("maker"),
      Json.str("query"),
      Json.str("estimateLowUsd"),
      Json.str("estimateHighUsd"),
      Json.str("basis"),
      Json.str("confidence"),
      Json.str("sources"),
      Json.str("where"),
    ]),
  ),
  ("additionalProperties", Json.boolJ(false)),
])

// The scene schema plus a required top-level otherCount.
let haulResponseSchema: JSON.t = Json.obj([
  ("type", Json.str("object")),
  (
    "properties",
    Json.obj([
      ("items", Json.obj([("type", Json.str("array")), ("items", haulItemSchema)])),
      ("otherCount", Json.obj([("type", Json.str("integer"))])),
    ]),
  ),
  ("required", Json.arr([Json.str("items"), Json.str("otherCount")])),
  ("additionalProperties", Json.boolJ(false)),
])

let haulOutputFormat: JSON.t = Json.obj([
  ("type", Json.str("json_schema")),
  ("schema", haulResponseSchema),
])

let haulPromptVersion = "haul-1"
