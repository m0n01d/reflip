// Decode the picked photo, scale it so the long edge is at most `longEdge`
// (never upscale), draw it on a detached canvas, and re-encode as JPEG at
// quality 0.85. `imageOrientation: "from-image"` on createImageBitmap keeps
// a portrait photo upright regardless of the camera's EXIF orientation tag.

// (w, h) scaled so the long edge is at most longEdge, preserving aspect
// ratio and never upscaling. Exposed for AppStateTest-style unit testing.
let scaleDims = (w: int, h: int, longEdge: int): (int, int) => {
  let longSide = w >= h ? w : h
  if longSide <= longEdge {
    (w, h)
  } else {
    let scale = Int.toFloat(longEdge) /. Int.toFloat(longSide)
    let outW = Float.toInt(Int.toFloat(w) *. scale)
    let outH = Float.toInt(Int.toFloat(h) *. scale)
    (outW < 1 ? 1 : outW, outH < 1 ? 1 : outH)
  }
}

let resizeToJpeg = async (file: WebApi.blob, longEdge: int): result<
  (WebApi.blob, float),
  string,
> => {
  let start = WebApi.now()
  try {
    let bitmap = await WebApi.createImageBitmap(file, {WebApi.imageOrientation: "from-image"})
    let w = WebApi.bitmapWidth(bitmap)
    let h = WebApi.bitmapHeight(bitmap)
    let (outW, outH) = scaleDims(w, h, longEdge)
    let canvas = WebApi.createElement(WebApi.document, "canvas")
    WebApi.setCanvasWidth(canvas, outW)
    WebApi.setCanvasHeight(canvas, outH)
    switch WebApi.getContext2d(canvas, "2d")->Nullable.toOption {
    | None => Error("this browser has no canvas 2d context")
    | Some(ctx) => {
        WebApi.drawImage(ctx, bitmap, 0.0, 0.0, Int.toFloat(outW), Int.toFloat(outH))
        let blobOpt = await Promise.make((resolve, _reject) =>
          WebApi.toBlobRaw(canvas, nb => resolve(nb->Nullable.toOption), "image/jpeg", 0.85)
        )
        switch blobOpt {
        | None => Error("could not encode that photo as JPEG")
        | Some(blob) => Ok((blob, WebApi.now() -. start))
        }
      }
    }
  } catch {
  | JsExn(_) => Error("could not read that photo")
  }
}
