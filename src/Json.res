// Small decode/encode helpers over the built-in JSON module. Every decode
// returns `option` — a malformed payload is data to branch on, never a cast
// or a crash (CLAUDE.md bans %identity and other type-system bypasses).

let field = (json: JSON.t, key: string): option<JSON.t> =>
  json->JSON.Decode.object->Option.flatMap(d => Dict.get(d, key))

let stringField = (json: JSON.t, key: string): option<string> =>
  field(json, key)->Option.flatMap(JSON.Decode.string)

let floatField = (json: JSON.t, key: string): option<float> =>
  field(json, key)->Option.flatMap(JSON.Decode.float)

let intField = (json: JSON.t, key: string): option<int> =>
  floatField(json, key)->Option.map(Float.toInt)

let arrayField = (json: JSON.t, key: string): option<array<JSON.t>> =>
  field(json, key)->Option.flatMap(JSON.Decode.array)

let boolField = (json: JSON.t, key: string): option<bool> =>
  field(json, key)->Option.flatMap(JSON.Decode.bool)

// The first balanced `{...}` span in `text`, honoring string literals and
// backslash escapes so a brace inside a JSON string value can't fool it.
// Used as the decode fallback when a model reply wraps its JSON in prose.
let firstJsonObjectSpan = (text: string): option<string> => {
  let len = String.length(text)
  let rec findStart = i =>
    if i >= len {
      None
    } else if String.charAt(text, i) == "{" {
      Some(i)
    } else {
      findStart(i + 1)
    }
  switch findStart(0) {
  | None => None
  | Some(start) => {
      let rec scan = (i, depth, inString, escaped) =>
        if i >= len {
          None
        } else {
          let c = String.charAt(text, i)
          if inString {
            if escaped {
              scan(i + 1, depth, true, false)
            } else if c == "\\" {
              scan(i + 1, depth, true, true)
            } else if c == "\"" {
              scan(i + 1, depth, false, false)
            } else {
              scan(i + 1, depth, true, false)
            }
          } else if c == "\"" {
            scan(i + 1, depth, true, false)
          } else if c == "{" {
            scan(i + 1, depth + 1, false, false)
          } else if c == "}" {
            if depth == 1 {
              Some(String.substring(text, ~start, ~end=i + 1))
            } else {
              scan(i + 1, depth - 1, false, false)
            }
          } else {
            scan(i + 1, depth, false, false)
          }
        }
      scan(start, 0, false, false)
    }
  }
}

// -- Encoding -------------------------------------------------------------

let obj = (pairs: array<(string, JSON.t)>): JSON.t => JSON.Encode.object(Dict.fromArray(pairs))
let arr = JSON.Encode.array
let str = JSON.Encode.string
let num = JSON.Encode.float
let boolJ = JSON.Encode.bool
