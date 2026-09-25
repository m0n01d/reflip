// Crops one item's box out of a haul photo with /usr/bin/sips, for the
// gem's thumbnail under the full photo in the haul digest email
// (docs/spec-haul-mode.md; a later agent wires this module in).
//
// withMargin follows src/web/BoxLayout.res's cropOf (L22-29): a 10% margin
// of the box's own width/height on each side, clamped to [0,width] x
// [0,height]. That module works in CSS pixels and never rounds, because
// its output stays float all the way to a `background-position` style.
// Here the margin has to land back in a `Types.box` (int fields), so the
// clamped float result is rounded the same way Box.res itself goes from
// float to int box coordinates (`Float.toInt(Math.round(v))`, see
// src/Box.res's `roundToInt`).

let withMargin = (box: Types.box, ~width: int, ~height: int): Types.box => {
  let bw = Int.toFloat(box.x2 - box.x1)
  let bh = Int.toFloat(box.y2 - box.y1)
  let marginX = bw *. 0.1
  let marginY = bh *. 0.1
  let x1 = Math.max(0.0, Int.toFloat(box.x1) -. marginX)
  let y1 = Math.max(0.0, Int.toFloat(box.y1) -. marginY)
  let x2 = Math.min(Int.toFloat(width), Int.toFloat(box.x2) +. marginX)
  let y2 = Math.min(Int.toFloat(height), Int.toFloat(box.y2) +. marginY)
  let roundToInt = (v: float): int => Float.toInt(Math.round(v))
  {
    Types.x1: roundToInt(x1),
    y1: roundToInt(y1),
    x2: roundToInt(x2),
    y2: roundToInt(y2),
  }
}

// Crops `box` (plus its 10% margin) out of `src` with sips, then scales the
// crop so its long edge is `longEdge`, never upscaling — the scale step is
// Thumb.make, reused as-is. The intermediate full-size crop is written to
// a temp file next to `dest` and removed once the scale step is done,
// whether or not it succeeded.
//
// Checked 2026-09-25: `sips -c H W --cropOffset Y X src --out dest` crops
// the WxH region whose top-left corner is (X, Y).
let make = (
  ~src: string,
  ~dest: string,
  ~box: Types.box,
  ~width: int,
  ~height: int,
  ~longEdge: int=240,
): result<unit, string> => {
  let m = withMargin(box, ~width, ~height)
  let cropW = m.x2 - m.x1
  let cropH = m.y2 - m.y1
  let tmpDest = dest ++ ".crop-tmp-" ++ Node.Crypto.randomUUID() ++ ".jpg"
  try {
    let _ = ChildProcess.execFileSync(
      Thumb.sipsPath,
      [
        "-c",
        Int.toString(cropH),
        Int.toString(cropW),
        "--cropOffset",
        Int.toString(m.y1),
        Int.toString(m.x1),
        src,
        "--out",
        tmpDest,
      ],
      {ChildProcess.encoding: "utf8"},
    )
    let result = Thumb.make(~src=tmpDest, ~dest, ~longEdge)
    Node.Fs.unlinkSync(tmpDest)
    result
  } catch {
  | JsExn(e) => Error("sips crop failed: " ++ JsExn.message(e)->Option.getOr("unknown error"))
  }
}
