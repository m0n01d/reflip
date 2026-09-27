// Streaming scanner for `{"items": [ {...}, {...} ], ...}` text. Tracks
// bracket depth and string/escape state so braces and brackets inside a
// JSON string value never confuse it. It only recognizes two shapes: the
// root object's "items" array, and one of its element's own "box" array
// — everything else is depth-tracked but otherwise ignored. The result
// does not depend on chunking: the scan only ever looks at the current
// character plus state carried over from previous feed() calls.

type found =
  | BoxClosed({index: int, box: array<int>})
  | ItemClosed({index: int, json: JSON.t})
  | ItemUnparsable({index: int, text: string})

type role =
  | RRoot
  | RItemsArray
  | RItem(int)
  | RBoxArray(int)
  | ROther

type frame = {
  role: role,
  isArray: bool,
  start: int,
  awaitingKey: bool,
  lastKey: string,
}

type t = {
  fullText: string,
  pos: int,
  stack: list<frame>,
  inString: bool,
  escaped: bool,
  stringStart: int,
  nextItemIndex: int,
}

let empty: t = {
  fullText: "",
  pos: 0,
  stack: list{},
  inString: false,
  escaped: false,
  stringStart: 0,
  nextItemIndex: 0,
}

let decodeBox = (text: string): option<array<int>> =>
  switch JsonCombinators.Json.parse(text) {
  | Error(_) => None
  | Ok(json) =>
      switch JsonCombinators.Json.decode(
        json,
        JsonCombinators.Json.Decode.array(JsonCombinators.Json.Decode.int),
      ) {
      | Ok(box) => Some(box)
      | Error(_) => None
      }
  }

let feed = (state: t, chunk: string): (t, array<found>) => {
  let fullText = state.fullText ++ chunk
  let len = String.length(fullText)
  let events: array<found> = []

  let rec scan = (
    pos: int,
    stack: list<frame>,
    inString: bool,
    escaped: bool,
    stringStart: int,
    nextItemIndex: int,
  ): t =>
    if pos >= len {
      {fullText, pos, stack, inString, escaped, stringStart, nextItemIndex}
    } else {
      let c = String.charAt(fullText, pos)
      if inString {
        if escaped {
          scan(pos + 1, stack, true, false, stringStart, nextItemIndex)
        } else if c == "\\" {
          scan(pos + 1, stack, true, true, stringStart, nextItemIndex)
        } else if c == "\"" {
          // The string just closed. If the top frame is an object still
          // awaiting its key, this string was that key.
          let stack2 = switch stack {
          | list{top, ...rest} if !top.isArray && top.awaitingKey =>
              let key = String.substring(fullText, ~start=stringStart + 1, ~end=pos)
              list{{...top, awaitingKey: false, lastKey: key}, ...rest}
          | _ => stack
          }
          scan(pos + 1, stack2, false, false, stringStart, nextItemIndex)
        } else {
          scan(pos + 1, stack, true, false, stringStart, nextItemIndex)
        }
      } else {
        switch c {
        | "\"" => scan(pos + 1, stack, true, false, pos, nextItemIndex)
        | "{" =>
            let (newRole, nextItemIndex2) = switch stack {
            | list{} => (RRoot, nextItemIndex)
            | list{top, ..._} =>
                if top.isArray {
                  switch top.role {
                  | RItemsArray => (RItem(nextItemIndex), nextItemIndex + 1)
                  | _ => (ROther, nextItemIndex)
                  }
                } else {
                  (ROther, nextItemIndex)
                }
            }
            let newFrame = {role: newRole, isArray: false, start: pos, awaitingKey: true, lastKey: ""}
            scan(pos + 1, list{newFrame, ...stack}, false, false, stringStart, nextItemIndex2)
        | "[" =>
            let newRole = switch stack {
            | list{} => ROther
            | list{top, ..._} =>
                if top.isArray {
                  ROther
                } else {
                  switch (top.role, top.lastKey) {
                  | (RRoot, "items") => RItemsArray
                  | (RItem(idx), "box") => RBoxArray(idx)
                  | _ => ROther
                  }
                }
            }
            let nextItemIndex2 = switch newRole {
            | RItemsArray => 0
            | _ => nextItemIndex
            }
            let newFrame = {role: newRole, isArray: true, start: pos, awaitingKey: false, lastKey: ""}
            scan(pos + 1, list{newFrame, ...stack}, false, false, stringStart, nextItemIndex2)
        | "}" =>
            switch stack {
            | list{top, ...rest} =>
                switch top.role {
                | RItem(idx) =>
                    let text = String.substring(fullText, ~start=top.start, ~end=pos + 1)
                    switch JsonCombinators.Json.parse(text) {
                    | Ok(json) => Array.push(events, ItemClosed({index: idx, json}))->ignore
                    | Error(_) => Array.push(events, ItemUnparsable({index: idx, text}))->ignore
                    }
                | _ => ()
                }
                scan(pos + 1, rest, false, false, stringStart, nextItemIndex)
            | list{} => scan(pos + 1, stack, false, false, stringStart, nextItemIndex)
            }
        | "]" =>
            switch stack {
            | list{top, ...rest} =>
                switch top.role {
                | RBoxArray(idx) =>
                    let text = String.substring(fullText, ~start=top.start, ~end=pos + 1)
                    switch decodeBox(text) {
                    | Some(box) => Array.push(events, BoxClosed({index: idx, box}))->ignore
                    | None => ()
                    }
                | _ => ()
                }
                scan(pos + 1, rest, false, false, stringStart, nextItemIndex)
            | list{} => scan(pos + 1, stack, false, false, stringStart, nextItemIndex)
            }
        | "," =>
            let stack2 = switch stack {
            | list{top, ...rest} if !top.isArray => list{{...top, awaitingKey: true}, ...rest}
            | _ => stack
            }
            scan(pos + 1, stack2, false, false, stringStart, nextItemIndex)
        | _ => scan(pos + 1, stack, false, false, stringStart, nextItemIndex)
        }
      }
    }

  let finalState = scan(
    state.pos,
    state.stack,
    state.inString,
    state.escaped,
    state.stringStart,
    state.nextItemIndex,
  )
  (finalState, events)
}
