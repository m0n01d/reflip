// Decodes, clamps, and rescales the box Claude reports for an item, per
// docs/spec-item-boxes.md's "Shape" section:
//
//   None if the box is missing, is not exactly 4 numbers, has x2 <= x1 or
//   y2 <= y1, or lies fully outside [0,seenW] x [0,seenH]. Clamp a partly-
//   outside box to seen. If seen differs from sent, scale each coordinate
//   by sent/seen and round.
//
// `sentWidth`/`sentHeight` are the size of the photo the page actually
// sent. `seen` is the size ImageSize.resizedSize says Claude saw for that
// model — they differ only on the standard tier (Haiku 4.5).

let decode = (
  rawBox: option<array<float>>,
  ~sentWidth: int,
  ~sentHeight: int,
  ~model: Shared.model,
): option<Types.box> =>
  switch rawBox {
  | None => None
  | Some(nums) if Array.length(nums) != 4 => None
  | Some(nums) => {
      let x1 = Array.getUnsafe(nums, 0)
      let y1 = Array.getUnsafe(nums, 1)
      let x2 = Array.getUnsafe(nums, 2)
      let y2 = Array.getUnsafe(nums, 3)
      if x2 <= x1 || y2 <= y1 {
        None
      } else {
        let (seenW, seenH) = ImageSize.resizedSize(ImageSize.tierFor(model), sentWidth, sentHeight)
        let seenWf = Int.toFloat(seenW)
        let seenHf = Int.toFloat(seenH)
        if x2 <= 0.0 || (x1 >= seenWf || (y2 <= 0.0 || y1 >= seenHf)) {
          None
        } else {
          let cx1 = Math.max(x1, 0.0)
          let cy1 = Math.max(y1, 0.0)
          let cx2 = Math.min(x2, seenWf)
          let cy2 = Math.min(y2, seenHf)
          let scaleX = Int.toFloat(sentWidth) /. seenWf
          let scaleY = Int.toFloat(sentHeight) /. seenHf
          let roundToInt = (v: float): int => Float.toInt(Math.round(v))
          Some({
            Types.x1: roundToInt(cx1 *. scaleX),
            y1: roundToInt(cy1 *. scaleY),
            x2: roundToInt(cx2 *. scaleX),
            y2: roundToInt(cy2 *. scaleY),
          })
        }
      }
    }
  }
