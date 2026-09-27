// ImageSize.resizedSize against the worked examples in the vision guide
// (see ImageSize.res's header comment for the source and date).

let run = () => {
  TestKit.section("ImageSize.resizedSize")

  TestKit.check(
    "standard tier: 1075x1520 -> 924x1307",
    ImageSize.resizedSize(ImageSize.standardTier, 1075, 1520) == (924, 1307),
  )
  TestKit.check(
    "standard tier: 1920x1080 -> 1456x819",
    ImageSize.resizedSize(ImageSize.standardTier, 1920, 1080) == (1456, 819),
  )
  TestKit.check(
    "high tier: 1920x1080 unchanged",
    ImageSize.resizedSize(ImageSize.highTier, 1920, 1080) == (1920, 1080),
  )
  TestKit.check(
    "high tier: 4032x3024 -> 2212x1659",
    ImageSize.resizedSize(ImageSize.highTier, 4032, 3024) == (2212, 1659),
  )
  TestKit.check(
    "high tier: 1568x1176 unchanged (already under 4784 tokens)",
    ImageSize.resizedSize(ImageSize.highTier, 1568, 1176) == (1568, 1176),
  )

  let (stdW, stdH) = ImageSize.resizedSize(ImageSize.standardTier, 1568, 1176)
  TestKit.check(
    "standard tier: 1568x1176 resizes to fit 1568 tokens",
    ImageSize.countImageTokens(stdW, stdH) <= 1568,
  )

  TestKit.check(
    "tierFor maps Opus 5.5 and Sonnet 5 to the high tier, Haiku 4.5 to standard",
    ImageSize.tierFor(Shared.Opus5_5) == ImageSize.highTier &&
      ImageSize.tierFor(Shared.Sonnet5) == ImageSize.highTier &&
      ImageSize.tierFor(Shared.Haiku4_5) == ImageSize.standardTier,
  )
}
