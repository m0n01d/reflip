// Reads a JPEG's pixel width and height straight from its encoded bytes, by
// walking segment markers from the SOI (FFD8) to the first SOFn marker
// (0xC0-0xCF, except the non-frame-header markers 0xC4 DHT, 0xC8 JPG
// reserved, and 0xCC DAC). The brain gets only the photo's raw bytes on
// POST /api/scene, so this is its only way to learn the size Claude will
// see (see ImageSize.res).

let isRestartOrStandalone = (marker: int): bool =>
  marker == 0xd8 || marker == 0xd9 || marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)

let isSofMarker = (marker: int): bool =>
  marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc

let readU8 = (buf: Node.Buffer.t, pos: int): option<int> =>
  pos < Node.Buffer.length(buf) ? Some(Node.Buffer.readUInt8(buf, pos)) : None

let readU16 = (buf: Node.Buffer.t, pos: int): option<int> =>
  pos + 1 < Node.Buffer.length(buf) ? Some(Node.Buffer.readUInt16BE(buf, pos)) : None

let dimensions = (buf: Node.Buffer.t): option<(int, int)> => {
  let rec walk = (pos: int): option<(int, int)> =>
    switch readU8(buf, pos) {
    | Some(0xff) =>
      switch readU8(buf, pos + 1) {
      | None => None
      | Some(0xff) => walk(pos + 1) // a fill byte before the real marker code
      | Some(marker) if isRestartOrStandalone(marker) => walk(pos + 2)
      | Some(marker) =>
        switch readU16(buf, pos + 2) {
        | None => None
        | Some(segLen) if segLen < 2 => None
        | Some(segLen) =>
          if isSofMarker(marker) {
            switch (readU16(buf, pos + 5), readU16(buf, pos + 7)) {
            | (Some(height), Some(width)) => Some((width, height))
            | _ => None
            }
          } else {
            walk(pos + 2 + segLen)
          }
        }
      }
    | _ => None
    }
  switch readU16(buf, 0) {
  | Some(0xffd8) => walk(2)
  | _ => None
  }
}
