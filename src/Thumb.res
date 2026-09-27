// Scales a JPEG to a target long-edge size with /usr/bin/sips. Thin glue
// around a subprocess — no ReScript-side image decoding. sips's own -Z flag
// upscales a small source to fit the target (checked by hand on this
// module's fixture: a 64x48 test image scaled -Z 480 comes back 480x360),
// so this module reads the source's pixel size first and only calls sips
// when the source is actually bigger than the target. A thrown
// child-process error (a missing /usr/bin/sips, or a non-zero exit) is
// caught through ReScript's `JsExn` pattern, never %raw or a swallowed
// exception.

let sipsPath = "/usr/bin/sips"

// Parses sips's `-g pixelWidth -g pixelHeight` stdout, e.g.:
//   /path/to/file.jpg
//     pixelWidth: 1200
//     pixelHeight: 800
let parseDimensions = (output: string): option<(int, int)> => {
  let lines = String.split(output, "\n")
  let find = (label: string): option<int> => {
    let prefix = label ++ ": "
    let rec go = i =>
      if i >= Array.length(lines) {
        None
      } else {
        let line = String.trim(Array.getUnsafe(lines, i))
        if String.startsWith(line, prefix) {
          Int.fromString(String.substring(line, ~start=String.length(prefix), ~end=String.length(line)))
        } else {
          go(i + 1)
        }
      }
    go(0)
  }
  switch (find("pixelWidth"), find("pixelHeight")) {
  | (Some(w), Some(h)) => Some((w, h))
  | _ => None
  }
}

let readDimensions = (src: string): result<(int, int), string> =>
  try {
    let out = ChildProcess.execFileSync(
      sipsPath,
      ["-g", "pixelWidth", "-g", "pixelHeight", src],
      {encoding: "utf8"},
    )
    switch parseDimensions(out) {
    | Some(dims) => Ok(dims)
    | None => Error("sips gave no readable pixel size for " ++ src)
    }
  } catch {
  | JsExn(e) => Error("sips is unavailable: " ++ JsExn.message(e)->Option.getOr("unknown error"))
  }

let resample = (~src: string, ~dest: string, ~longEdge: int): result<unit, string> =>
  try {
    let _ = ChildProcess.execFileSync(
      sipsPath,
      ["-Z", Int.toString(longEdge), src, "--out", dest],
      {encoding: "utf8"},
    )
    Ok()
  } catch {
  | JsExn(e) => Error("sips resample failed: " ++ JsExn.message(e)->Option.getOr("unknown error"))
  }

let copyAsIs = (~src: string, ~dest: string): result<unit, string> =>
  try {
    Node.Fs.copyFileSync(src, dest)
    Ok()
  } catch {
  | JsExn(e) => Error("copy failed: " ++ JsExn.message(e)->Option.getOr("unknown error"))
  }

// Never upscales: a source already at or under `longEdge` is copied as-is.
let make = (~src: string, ~dest: string, ~longEdge: int): result<unit, string> =>
  switch readDimensions(src) {
  | Error(e) => Error(e)
  | Ok((w, h)) =>
    let long = w > h ? w : h
    if long <= longEdge {
      copyAsIs(~src, ~dest)
    } else {
      resample(~src, ~dest, ~longEdge)
    }
  }
