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
}
