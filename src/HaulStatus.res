// Builds the GET /api/hauls/:id (and POST /api/hauls, POST .../done) reply
// from the store. Pure read: no mutation, no Claude or eBay call. Per
// docs/spec-haul-mode.md "The brain" and "Gems", and CLAUDE.md's Store rules
// (a row decode returns option, never a cast).

// Gems, best first (highest estimateLowUsd). A find is a gem when its
// estimateHighUsd meets the haul's gem threshold, per "Gems" in the spec.
// sceneSizes maps a scene's id to the width/height stored at upload
// (Store.res "How it fits together"), so a gem's crop can scale against the
// same photo its box was measured on, without gemsOf re-querying the store.
let sceneSizesOf = (scenes: array<Store.scene>): Dict.t<(option<int>, option<int>)> => {
  let d = Dict.make()
  Array.forEach(scenes, s => Dict.set(d, s.sceneId, (s.imageWidth, s.imageHeight)))
  d
}

let gemsOf = (
  finds: array<Store.find>,
  gemMinUsd: float,
  sceneSizes: Dict.t<(option<int>, option<int>)>,
): array<Types.haulGem> =>
  finds
  ->Array.filter(f => f.estimateHighUsd >= gemMinUsd)
  ->Array.map(f => {
      let (imageWidth, imageHeight) =
        Dict.get(sceneSizes, f.sceneId)->Option.getOr((None, None))
      {
        Types.findId: f.findId,
        sceneId: f.sceneId,
        name: f.name,
        where: f.where,
        estimateLowUsd: f.estimateLowUsd,
        estimateHighUsd: f.estimateHighUsd,
        confidence: f.confidence,
        soldSearchUrl: EbayClient.soldSearchUrl(f.query),
        ebay: f.ebayJson->Option.flatMap(text =>
          switch JSON.parseOrThrow(text) {
          | json =>
            switch Shared.decodeEbayStats(json) {
            | Ok(stats) => Some(stats)
            | Error(_) => None
            }
          | exception JsExn(_) => None
          }
        ),
        box: f.box,
        imageWidth,
        imageHeight,
        size: f.size,
        profit: Store.profitOf(f),
      }
    })
  ->Array.toSorted((a, b) => Float.compare(b.Types.estimateLowUsd, a.Types.estimateLowUsd))

let failedOf = (scenes: array<Store.scene>): array<Types.failedPhoto> =>
  scenes
  ->Array.filter(s => s.status == Store.Failed)
  ->Array.map(s => {Types.sceneId: s.sceneId, error: s.error->Option.getOr("unknown error")})

let build = (db: Store.t, config: Config.t, haulId: string): option<Types.haulStatus> =>
  switch Store.getHaul(db, haulId) {
  | None => None
  | Some(haul) => {
      let counts = Store.counts(db, haulId)
      let scenes = Store.scenesOf(db, haulId)
      let finds = Store.findsOf(db, haulId)
      let gems = gemsOf(finds, config.haulGemMinUsd, sceneSizesOf(scenes))
      // Other items: finds below the gem threshold, plus each scene's own
      // otherCount (the items the haul prompt only counted, step 4). None
      // (no haul prompt used yet, or a scene that isn't done) reads as 0.
      let otherFinds = Array.length(finds) - Array.length(gems)
      let otherFromScenes = Array.reduce(scenes, 0, (acc, s) => acc + s.otherCount->Option.getOr(0))
      Some({
        Types.haulId: haul.haulId,
        name: haul.name,
        startedAt: haul.startedAt,
        doneAt: haul.doneAt,
        emailedAt: haul.emailedAt,
        costUsd: haul.costUsd,
        maxUsd: config.haulMaxUsd,
        gemMinUsd: config.haulGemMinUsd,
        stopReason: haul.stopReason,
        emailNote: haul.emailNote,
        counts: {
          Types.queued: counts.queued,
          running: counts.running,
          valued: counts.done,
          failed: counts.failed,
        },
        gems,
        otherCount: otherFinds + otherFromScenes,
        failed: failedOf(scenes),
        place: haul.place,
      })
    }
  }
