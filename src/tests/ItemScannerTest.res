// ItemScanner: nested braces/brackets, escaped quotes inside strings (one
// outside "items" entirely, one inside an item's own value), a
// "sources" array that must not be mistaken for "box", one item with a
// box and one item without, and chunking independence: every fixed
// chunk size from 1 to the text length, plus 50 seeded random splits.

let text = "{\"meta\": {\"note\": \"he said \\\"hi\\\"\"}, \"items\": [{\"name\": \"Widget\", \"tags\": [\"a\", \"b\"], \"box\": [1, 2, 3, 4], \"nested\": {\"x\": {\"y\": 1}}}, {\"name\": \"Gadget \\\"deluxe\\\"\", \"sources\": [\"http://x.test/a\", \"http://x.test/b\"]}]}"

let expectedItems: array<JSON.t> = Json.arrayField(JSON.parseOrThrow(text), "items")->Option.getOr([])

let scanInChunksOf = (chunkSize: int): array<ItemScanner.found> => {
  let len = String.length(text)
  let rec go = (
    pos: int,
    state: ItemScanner.t,
    acc: array<ItemScanner.found>,
  ): array<ItemScanner.found> =>
    if pos >= len {
      acc
    } else {
      let endPos = pos + chunkSize > len ? len : pos + chunkSize
      let chunk = String.substring(text, ~start=pos, ~end=endPos)
      let (newState, found) = ItemScanner.feed(state, chunk)
      go(endPos, newState, Array.concat(acc, found))
    }
  go(0, ItemScanner.empty, [])
}

// A small deterministic mixer (not cryptographic, just reproducible) so
// "50 seeded random splits" means the same 50 splits on every run.
let scanWithRandomChunks = (seed: int): array<ItemScanner.found> => {
  let len = String.length(text)
  let rec go = (
    pos: int,
    a: int,
    b: int,
    state: ItemScanner.t,
    acc: array<ItemScanner.found>,
  ): array<ItemScanner.found> =>
    if pos >= len {
      acc
    } else {
      let a2 = (a * 3 + 5) % 10007
      let b2 = (b * 7 + 11) % 10007
      let size = (a2 + b2) % 7 + 1
      let endPos = pos + size > len ? len : pos + size
      let chunk = String.substring(text, ~start=pos, ~end=endPos)
      let (newState, found) = ItemScanner.feed(state, chunk)
      go(endPos, a2, b2, newState, Array.concat(acc, found))
    }
  go(0, seed, seed + 1, ItemScanner.empty, [])
}

let itemsMatch = (found: array<ItemScanner.found>): bool => {
  let closedItems = Array.filterMap(found, f =>
    switch f {
    | ItemScanner.ItemClosed({json}) => Some(json)
    | _ => None
    }
  )
  JSON.stringify(Json.arr(closedItems)) == JSON.stringify(Json.arr(expectedItems))
}

let boxesPrecedeItems = (found: array<ItemScanner.found>): bool => {
  let indexed = Array.mapWithIndex(found, (f, i) => (i, f))
  let boxPositions = Array.filterMap(indexed, ((i, f)) =>
    switch f {
    | ItemScanner.BoxClosed({index}) => Some((index, i))
    | _ => None
    }
  )
  let itemPositions = Array.filterMap(indexed, ((i, f)) =>
    switch f {
    | ItemScanner.ItemClosed({index}) => Some((index, i))
    | _ => None
    }
  )
  let ok = ref(true)
  for i in 0 to Array.length(itemPositions) - 1 {
    switch Array.get(itemPositions, i) {
    | Some((idx, itemPos)) =>
        switch Array.find(boxPositions, ((bidx, _)) => bidx == idx) {
        | Some((_, boxPos)) =>
            if boxPos >= itemPos {
              ok := false
            }
        | None => ()
        }
    | None => ()
    }
  }
  ok.contents
}

let run = () => {
  TestKit.section("ItemScanner")

  TestKit.check("fixture text has 2 items", Array.length(expectedItems) == 2)

  let len = String.length(text)
  let allChunkSizesOk = ref(true)
  for size in 1 to len {
    let found = scanInChunksOf(size)
    if !itemsMatch(found) || !boxesPrecedeItems(found) {
      allChunkSizesOk := false
    }
  }
  TestKit.check("every chunk size from 1 to length reconstructs the items", allChunkSizesOk.contents)

  let allRandomOk = ref(true)
  for seed in 1 to 50 {
    let found = scanWithRandomChunks(seed)
    if !itemsMatch(found) || !boxesPrecedeItems(found) {
      allRandomOk := false
    }
  }
  TestKit.check("50 seeded random splits reconstruct the items", allRandomOk.contents)

  let (_, wholeFound) = ItemScanner.feed(ItemScanner.empty, text)
  TestKit.check("single-chunk feed: items match JSON.parse(text).items", itemsMatch(wholeFound))
  TestKit.check("single-chunk feed: box precedes its item", boxesPrecedeItems(wholeFound))
}
