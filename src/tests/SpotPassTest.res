// SpotPass: the 30-item cap (brain-followups track, docs/scan-ui.md §6).
// A spot reply with 31 items must produce exactly 30 ItemFound events,
// indexes 0 to 29 -- item 30 gets no event and does not reach the
// outcome. Also checks that spotSchema's items array carries the cap as
// a description string, not a maxItems constraint (see the comment next
// to SystemPrompt.spotMaxItems for the structured-outputs docs citation).

let itemJson = (i: int): string =>
  "{\"name\": \"Item " ++ Int.toString(i) ++ "\", \"box\": [0, 0, 10, 10]}"

let itemsText = (n: int): string => {
  let parts: array<string> = []
  for i in 0 to n - 1 {
    Array.push(parts, itemJson(i))->ignore
  }
  "{\"items\": [" ++ Array.join(parts, ", ") ++ "]}"
}

let itemFoundIndexes = (events: array<SpotPass.logEvent>): array<int> =>
  Array.filterMap(events, evt =>
    switch evt {
    | SpotPass.ItemFound({index}) => Some(index)
    | _ => None
    }
  )

let joinInts = (xs: array<int>): string => Array.join(Array.map(xs, i => Int.toString(i)), ",")

let run = () => {
  TestKit.section("SpotPass")

  let text = itemsText(31)
  let (_, found) = ItemScanner.feed(ItemScanner.empty, text)
  let (_, events) = SpotPass.applyFoundAll(SpotPass.init, found)
  let indexes = itemFoundIndexes(events)

  TestKit.check("31 items in produces exactly 30 ItemFound events", Array.length(indexes) == 30)

  let expectedIndexes: array<int> = {
    let acc = []
    for i in 0 to 29 {
      Array.push(acc, i)->ignore
    }
    acc
  }
  TestKit.check(
    "the 30 ItemFound events are indexes 0 to 29",
    joinInts(indexes) == joinInts(expectedIndexes),
  )

  let itemsArraySchema =
    Json.field(SystemPrompt.spotSchema, "properties")->Option.flatMap(p => Json.field(p, "items"))

  let description = itemsArraySchema->Option.flatMap(s => Json.stringField(s, "description"))
  TestKit.check(
    "the spot schema's items array has a description with the cap",
    description == Some("At most " ++ Int.toString(SystemPrompt.spotMaxItems) ++ " items."),
  )

  let maxItemsKey = itemsArraySchema->Option.flatMap(s => Json.field(s, "maxItems"))
  TestKit.check("the spot schema's items array has no maxItems key", maxItemsKey->Option.isNone)
}
