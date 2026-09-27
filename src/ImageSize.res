// Ports the reference resize function from the vision guide's "Coordinates
// and bounding boxes" page (platform.claude.com/docs/en/build-with-claude/
// vision-coordinates, read 2026-09-24). Pure: no Node imports, so it also
// compiles into the browser bundle (see reflip's CLAUDE.md file map).
//
// The brain uses this to learn the size Claude actually saw for a given
// model, so it can rescale a box back onto the photo the page sent.

type tier = {maxEdge: int, maxTokens: int}

// claude-opus-5-5 and claude-sonnet-5 are the high-resolution tier (2576px /
// 4784 tokens); claude-haiku-4-5 is the standard tier (1568px / 1568
// tokens). Per the spec's "Shape" section.
let standardTier: tier = {maxEdge: 1568, maxTokens: 1568}
let highTier: tier = {maxEdge: 2576, maxTokens: 4784}

// Maps from Shared.model, never a copied model id string.
let tierFor = (m: Shared.model): tier =>
  switch m {
  | Shared.Opus5_5 | Shared.Sonnet5 => highTier
  | Shared.Haiku4_5 => standardTier
  }

let maxInt = (a: int, b: int): int => a > b ? a : b

let ceilDivBy28 = (n: int): int => Float.toInt(Math.ceil(Int.toFloat(n) /. 28.0))

let countImageTokens = (width: int, height: int): int => ceilDivBy28(width) * ceilDivBy28(height)

// JS Math.round rounds an exact .5 fraction up (toward +infinity). The
// reference function special-cases an exact .5 fraction to round to the
// nearest even integer instead — that difference is why this is its own
// function rather than a call to Math.round.
let roundTiesToEven = (v: float): int => {
  let f = Math.floor(v)
  if v -. f != 0.5 {
    Float.toInt(Math.round(v))
  } else {
    let fi = Float.toInt(f)
    mod(fi, 2) == 0 ? fi : fi + 1
  }
}

let fits = (tier: tier, w: int, h: int): bool =>
  ceilDivBy28(w) * 28 <= tier.maxEdge &&
  (ceilDivBy28(h) * 28 <= tier.maxEdge && countImageTokens(w, h) <= tier.maxTokens)

// The size Claude actually sees for a photo of (width, height) at `tier`.
// Returns (width, height) unchanged when it already fits.
let rec resizedSize = (tier: tier, width: int, height: int): (int, int) =>
  if fits(tier, width, height) {
    (width, height)
  } else if height > width {
    let (rh, rw) = resizedSize(tier, height, width)
    (rw, rh)
  } else {
    let aspect = Int.toFloat(width) /. Int.toFloat(height)
    let heightFor = (w: int): int => maxInt(roundTiesToEven(Int.toFloat(w) /. aspect), 1)
    let rec search = (lo: int, hi: int): int =>
      if lo + 1 < hi {
        let mid = (lo + hi) / 2
        if fits(tier, mid, heightFor(mid)) {
          search(mid, hi)
        } else {
          search(lo, mid)
        }
      } else {
        lo
      }
    let lo = search(1, width)
    (lo, heightFor(lo))
  }
