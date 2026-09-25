// Digest.make is pure, so every assertion here is hand-computed against the
// literal input below — no fixture file, no network.

let run = () => {
  TestKit.section("Digest.make")

  let weird: Digest.gem = {
    name: "Weird <b>& Thing",
    where: Some("top shelf"),
    estimateLowUsd: 20.0,
    estimateHighUsd: 30.0,
    confidence: 0.6,
    soldSearchUrl: "https://www.ebay.com/sch/i.html?_nkw=weird+thing&LH_Sold=1",
    sceneId: "scene-a",
    ebayMedianUsd: None,
    size: "",
    crop: None,
  }
  let lamp: Digest.gem = {
    name: "Old Lamp",
    where: Some("back shelf"),
    estimateLowUsd: 25.0,
    estimateHighUsd: 40.0,
    confidence: 0.75,
    soldSearchUrl: "https://www.ebay.com/sch/i.html?_nkw=old+lamp&LH_Sold=1",
    sceneId: "scene-c",
    ebayMedianUsd: None,
    size: "",
    crop: None,
  }
  let radio: Digest.gem = {
    name: "Vintage Radio",
    where: None,
    estimateLowUsd: 35.0,
    estimateHighUsd: 85.0,
    confidence: 0.9,
    soldSearchUrl: "https://www.ebay.com/sch/i.html?_nkw=vintage+radio&LH_Sold=1",
    sceneId: "scene-b",
    ebayMedianUsd: Some(60.0),
    size: "12 in",
    crop: None,
  }

  // Given out of order: [weird(20), lamp(25), radio(35)].
  let sorted = Digest.sortGems([weird, lamp, radio])
  TestKit.check(
    "3 gems given out of order come out sorted, highest estimateLowUsd first (1/3)",
    (Array.getUnsafe(sorted, 0): Digest.gem).name == "Vintage Radio",
  )
  TestKit.check(
    "3 gems given out of order come out sorted, highest estimateLowUsd first (2/3)",
    (Array.getUnsafe(sorted, 1): Digest.gem).name == "Old Lamp",
  )
  TestKit.check(
    "3 gems given out of order come out sorted, highest estimateLowUsd first (3/3)",
    (Array.getUnsafe(sorted, 2): Digest.gem).name == "Weird <b>& Thing",
  )

  let input: Digest.input = {
    haulId: "haul-1",
    name: Some("Goodwill"),
    startedAt: "2026-09-24T10:00:00Z",
    costUsd: 1.52,
    stopReason: None,
    gemMinUsd: 20.0,
    gems: [weird, lamp, radio],
    otherCount: 7,
    valuedCount: 10,
    failed: [{Digest.sceneId: "scene-x", error: "reply cut off"}],
  }

  let cidFor = sceneId => "cid-" ++ sceneId
  let digest = Digest.make(input, ~cidFor)

  TestKit.check(
    "exact subject string, with a real en dash and the store name",
    digest.subject == "reflip haul: 3 gems, best $35–$85 (Goodwill)",
  )

  TestKit.check(
    "the cost shows cents in both bodies",
    String.includes(digest.html, "cost $1.52") && String.includes(digest.text, "cost $1.52"),
  )

  TestKit.check(
    "a name with <b>& is escaped in the html body",
    String.includes(digest.html, "Weird &lt;b&gt;&amp; Thing"),
  )
  TestKit.check(
    "the raw, unescaped <b>& never appears in the html body",
    !String.includes(digest.html, "<b>&"),
  )

  TestKit.check("scene-a's cid appears in the html body", String.includes(digest.html, "cid:cid-scene-a"))
  TestKit.check("scene-b's cid appears in the html body", String.includes(digest.html, "cid:cid-scene-b"))
  TestKit.check("scene-c's cid appears in the html body", String.includes(digest.html, "cid:cid-scene-c"))

  TestKit.check(
    "a non-empty size shows after the name in the html body",
    String.includes(digest.html, "Vintage Radio (12 in)"),
  )
  TestKit.check(
    "a non-empty size shows after the name in the text body",
    String.includes(digest.text, "Vintage Radio (12 in)"),
  )
  TestKit.check(
    "an empty size shows nothing extra after the name in the html body",
    String.includes(digest.html, "Old Lamp</div>") && !String.includes(digest.html, "Old Lamp ("),
  )
  TestKit.check(
    "an empty size shows nothing extra after the name in the text body",
    String.includes(digest.text, "Old Lamp\n") && !String.includes(digest.text, "Old Lamp ("),
  )

  TestKit.check("the other-items count appears in the html body", String.includes(digest.html, "7 other items"))
  TestKit.check("the other-items count appears in the text body", String.includes(digest.text, "7 other items"))

  TestKit.check(
    "the failed photo's scene id appears in the html body",
    String.includes(digest.html, "scene-x"),
  )
  TestKit.check(
    "the failed photo's error appears in the html body",
    String.includes(digest.html, "reply cut off"),
  )
  TestKit.check(
    "the failed photo's scene id and error appear in the text body",
    String.includes(digest.text, "scene-x") && String.includes(digest.text, "reply cut off"),
  )

  // Zero gems: a sensible subject, no gem thumbnails, still lists the count
  // and the failure.
  let emptyInput = {...input, gems: [], name: None}
  let emptyDigest = Digest.make(emptyInput, ~cidFor)
  TestKit.check(
    "a haul with no gems gets a sensible subject with no store name",
    emptyDigest.subject == "reflip haul: no gems",
  )
  TestKit.check(
    "a haul with no gems says so in the html body",
    String.includes(emptyDigest.html, "No gems this haul."),
  )

  // -- grouping by photo --------------------------------------------------

  TestKit.section("Digest.make groups gems by photo")

  // 6 gems over 3 photos (scene-2, scene-1, scene-3), given already in
  // Digest.sortGems order (each estimateLowUsd is distinct, so no tie
  // breaking matters). scene-2 gets 3 gems, scene-1 gets 2, scene-3 gets
  // 1. A 4th photo, scene-4, has no gem at all — nothing below ever
  // mentions it, because a photo with no gem has nothing in `gems` to put
  // it there (there is no separate "list of photos" input to leave it out
  // of).
  let g1: Digest.gem = {
    name: "Gem A1",
    where: None,
    estimateLowUsd: 100.0,
    estimateHighUsd: 150.0,
    confidence: 0.9,
    soldSearchUrl: "https://www.ebay.com/sch/i.html?_nkw=gem+a1&LH_Sold=1",
    sceneId: "scene-2",
    ebayMedianUsd: None,
    size: "",
    crop: Some({Digest.cid: "cid-a1", width: 200, height: 150}),
  }
  let g2: Digest.gem = {
    name: "Gem A2",
    where: None,
    estimateLowUsd: 90.0,
    estimateHighUsd: 120.0,
    confidence: 0.8,
    soldSearchUrl: "https://www.ebay.com/sch/i.html?_nkw=gem+a2&LH_Sold=1",
    sceneId: "scene-1",
    ebayMedianUsd: None,
    size: "",
    crop: Some({Digest.cid: "cid-a2", width: 180, height: 135}),
  }
  let g3: Digest.gem = {
    name: "Gem A3",
    where: None,
    estimateLowUsd: 80.0,
    estimateHighUsd: 110.0,
    confidence: 0.7,
    soldSearchUrl: "https://www.ebay.com/sch/i.html?_nkw=gem+a3&LH_Sold=1",
    sceneId: "scene-2",
    ebayMedianUsd: None,
    size: "",
    crop: Some({Digest.cid: "cid-a3", width: 150, height: 200}),
  }
  let g4: Digest.gem = {
    name: "Gem A4",
    where: None,
    estimateLowUsd: 70.0,
    estimateHighUsd: 95.0,
    confidence: 0.6,
    soldSearchUrl: "https://www.ebay.com/sch/i.html?_nkw=gem+a4&LH_Sold=1",
    sceneId: "scene-3",
    ebayMedianUsd: None,
    size: "",
    crop: Some({Digest.cid: "cid-a4", width: 120, height: 240}),
  }
  let g5: Digest.gem = {
    name: "Gem A5",
    where: None,
    estimateLowUsd: 60.0,
    estimateHighUsd: 85.0,
    confidence: 0.5,
    soldSearchUrl: "https://www.ebay.com/sch/i.html?_nkw=gem+a5&LH_Sold=1",
    sceneId: "scene-1",
    ebayMedianUsd: None,
    size: "",
    crop: Some({Digest.cid: "cid-a5", width: 100, height: 80}),
  }
  // A6 has no box (its Store find's box was None, or the crop failed) —
  // Digest.gemHtml shows "no box" and adds no image for it.
  let g6: Digest.gem = {
    name: "Gem A6",
    where: None,
    estimateLowUsd: 50.0,
    estimateHighUsd: 75.0,
    confidence: 0.4,
    soldSearchUrl: "https://www.ebay.com/sch/i.html?_nkw=gem+a6&LH_Sold=1",
    sceneId: "scene-2",
    ebayMedianUsd: None,
    size: "",
    crop: None,
  }

  // Given out of order; Digest.make sorts them itself.
  let groupedInput: Digest.input = {
    haulId: "haul-2",
    name: Some("Thrift Barn"),
    startedAt: "2026-09-25T09:00:00Z",
    costUsd: 2.10,
    stopReason: None,
    gemMinUsd: 20.0,
    gems: [g4, g1, g6, g2, g5, g3],
    otherCount: 3,
    valuedCount: 4,
    failed: [],
  }
  let groupedCidFor = sceneId => "photo-" ++ sceneId
  let grouped = Digest.make(groupedInput, ~cidFor=groupedCidFor)

  // Sorted overall (by estimateLowUsd, highest first): A1(100,scene-2),
  // A2(90,scene-1), A3(80,scene-2), A4(70,scene-3), A5(60,scene-1),
  // A6(50,scene-2). Subject uses only the sorted order, unchanged by
  // grouping.
  TestKit.check(
    "the subject is unchanged by grouping: 6 gems, best from A1",
    grouped.subject == "reflip haul: 6 gems, best $100–$150 (Thrift Barn)",
  )

  // Section rank = each scene's first gem's rank in that sorted order:
  // scene-2 first (from A1), then scene-1 (from A2), then scene-3 (from
  // A4). So the sections are, in this order: scene-2 (3 gems), scene-1 (2
  // gems), scene-3 (1 gem).
  TestKit.check(
    "section 1 heading: scene-2, 3 gems, plural",
    String.includes(grouped.html, "Photo 1 · 3 gems"),
  )
  TestKit.check(
    "section 2 heading: scene-1, 2 gems, plural",
    String.includes(grouped.html, "Photo 2 · 2 gems"),
  )
  TestKit.check(
    "section 3 heading: scene-3, 1 gem, singular",
    String.includes(grouped.html, "Photo 3 · 1 gem") &&
      !String.includes(grouped.html, "Photo 3 · 1 gems"),
  )

  // Section order: heading 1 before heading 2 before heading 3.
  let idxPhoto1 = String.indexOf(grouped.html, "Photo 1 · 3 gems")
  let idxPhoto2 = String.indexOf(grouped.html, "Photo 2 · 2 gems")
  let idxPhoto3 = String.indexOf(grouped.html, "Photo 3 · 1 gem")
  TestKit.check(
    "sections come in rank order: photo 1, then photo 2, then photo 3",
    idxPhoto1 >= 0 && idxPhoto2 > idxPhoto1 && idxPhoto3 > idxPhoto2,
  )

  // Each photo's whole-photo cid (groupedCidFor(sceneId)) appears once,
  // right under its own heading — i.e. after that section's heading and
  // before the next one.
  let idxPhotoImgScene2 = String.indexOf(grouped.html, "cid:photo-scene-2")
  let idxPhotoImgScene1 = String.indexOf(grouped.html, "cid:photo-scene-1")
  let idxPhotoImgScene3 = String.indexOf(grouped.html, "cid:photo-scene-3")
  TestKit.check(
    "scene-2's whole-photo image sits inside section 1",
    idxPhotoImgScene2 > idxPhoto1 && idxPhotoImgScene2 < idxPhoto2,
  )
  TestKit.check(
    "scene-1's whole-photo image sits inside section 2",
    idxPhotoImgScene1 > idxPhoto2 && idxPhotoImgScene1 < idxPhoto3,
  )
  TestKit.check("scene-3's whole-photo image sits inside section 3", idxPhotoImgScene3 > idxPhoto3)

  // The whole-photo <img> caps at 640px on a wide desktop client, instead
  // of stretching to fill it (width="100%" alone has no such cap).
  TestKit.check(
    "the whole-photo image style caps at max-width:640px",
    String.includes(grouped.html, "max-width:640px"),
  )

  // Gem order inside section 1 (scene-2): A1, then A3, then A6 — the same
  // order they appear in the overall sortGems order.
  let idxA1 = String.indexOf(grouped.html, "Gem A1")
  let idxA3 = String.indexOf(grouped.html, "Gem A3")
  let idxA6 = String.indexOf(grouped.html, "Gem A6")
  TestKit.check(
    "gems inside section 1 stay in sortGems order: A1, A3, A6",
    idxA1 >= 0 && idxA3 > idxA1 && idxA6 > idxA3,
  )

  // Gem order inside section 2 (scene-1): A2, then A5.
  let idxA2 = String.indexOf(grouped.html, "Gem A2")
  let idxA5 = String.indexOf(grouped.html, "Gem A5")
  TestKit.check("gems inside section 2 stay in sortGems order: A2, A5", idxA2 >= 0 && idxA5 > idxA2)

  // A1, A2, A3, A4, A5 each got a crop image; A6 did not.
  TestKit.check("A1's crop cid appears", String.includes(grouped.html, "cid:cid-a1"))
  TestKit.check("A2's crop cid appears", String.includes(grouped.html, "cid:cid-a2"))
  TestKit.check("A3's crop cid appears", String.includes(grouped.html, "cid:cid-a3"))
  TestKit.check("A4's crop cid appears", String.includes(grouped.html, "cid:cid-a4"))
  TestKit.check("A5's crop cid appears", String.includes(grouped.html, "cid:cid-a5"))
  TestKit.check("A6 has no crop cid (it has no box)", !String.includes(grouped.html, "cid:cid-a6"))
  TestKit.check("A6's card shows \"no box\" in place of a crop", String.includes(grouped.html, "no box"))

  // A4's crop is portrait (120x240, taller than it is wide) — its <img>
  // must render at its own real size, not the old fixed 240px width that
  // would have upscaled and mis-sized it.
  TestKit.check(
    "A4's portrait crop (120x240) renders width=\"120\" height=\"240\"",
    String.includes(grouped.html, "width=\"120\" height=\"240\""),
  )
  // None of the fixture crops is really 240px wide, so a literal
  // width="240" would only appear if Digest.gemHtml were still hard-coding
  // it instead of using each gem's own crop size.
  TestKit.check(
    "no crop image is hard-coded to width=\"240\" (none of these is really 240px wide)",
    !String.includes(grouped.html, "width=\"240\""),
  )

  // The text body is grouped the same way: a heading line per photo, then
  // its gems, with no image lines at all (the text body never had any).
  let tIdxPhoto1 = String.indexOf(grouped.text, "Photo 1 · 3 gems")
  let tIdxPhoto2 = String.indexOf(grouped.text, "Photo 2 · 2 gems")
  let tIdxPhoto3 = String.indexOf(grouped.text, "Photo 3 · 1 gem")
  TestKit.check(
    "the text body has the same 3 headings in the same order",
    tIdxPhoto1 >= 0 && tIdxPhoto2 > tIdxPhoto1 && tIdxPhoto3 > tIdxPhoto2,
  )
  TestKit.check("the text body names every gem", String.includes(grouped.text, "Gem A6"))
  TestKit.check("the text body never mentions cid: (no image lines)", !String.includes(grouped.text, "cid:"))
}
