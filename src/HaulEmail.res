// Builds and delivers the haul-done digest email. `HaulWorker.checkDrained`
// calls `send` once per drained haul (see `onDrained` in `Server.start`),
// per docs/spec-haul-mode.md "The digest and the email" and the build
// plan's "Step 6: digest and email".
//
// With `FIXTURES=1`, or a missing Gmail secret outside fixture mode, the
// digest is written to `data/outbox/<haulId>.eml` and nothing is sent —
// hard rule 3 in CLAUDE.md (secrets from the environment only). A send
// error also falls back to the outbox, so a drained haul never loses its
// digest. `Store.markEmailed` always runs exactly once, with a note that
// says which of the three happened.

let outboxDir = (config: Config.t): string => Node.Path.join([config.dataDir, "outbox"])

// The literal path the spec and this note use, independent of the actual
// (possibly tmp, in a test) `dataDir` — see docs/spec-haul-mode.md, "The
// digest and the email".
let outboxNoteName = (haulId: string): string => "data/outbox/" ++ haulId ++ ".eml"

let cidFor = (sceneId: string): string => "scene-" ++ sceneId ++ "@reflip"

// Concatenates `parts` with ", " between them, without relying on an
// unverified Array.join in the ReScript 12 stdlib (same reasoning as
// Digest.res's `concatAll`).
let joinComma = (parts: array<string>): string =>
  Array.reduceWithIndex(parts, "", (acc, part, i) => i == 0 ? part : acc ++ ", " ++ part)

// Same gem rule as HaulStatus.gemsOf (estimateHighUsd >= the threshold),
// built for Digest.res's gem shape instead of Types.haulGem: it wants only
// the eBay median, not the full stats blob.
let digestGemsOf = (finds: array<Store.find>, gemMinUsd: float): array<Digest.gem> =>
  finds
  ->Array.filter(f => f.estimateHighUsd >= gemMinUsd)
  ->Array.map(f => {
      Digest.name: f.name,
      where: f.where,
      estimateLowUsd: f.estimateLowUsd,
      estimateHighUsd: f.estimateHighUsd,
      confidence: f.confidence,
      soldSearchUrl: EbayClient.soldSearchUrl(f.query),
      sceneId: f.sceneId,
      ebayMedianUsd: f.ebayJson->Option.flatMap(text =>
        switch JSON.parseOrThrow(text) {
        | json =>
          switch Shared.decodeEbayStats(json) {
          | Ok(stats) => Some(stats.medianUsd)
          | Error(_) => None
          }
        | exception JsExn(_) => None
        }
      ),
    })

let digestFailedOf = (scenes: array<Store.scene>): array<Digest.failedPhoto> =>
  scenes
  ->Array.filter(s => s.status == Store.Failed)
  ->Array.map(s => {Digest.sceneId: s.sceneId, error: s.error->Option.getOr("unknown error")})

let digestInputOf = (
  config: Config.t,
  haul: Store.haul,
  scenes: array<Store.scene>,
  finds: array<Store.find>,
  counts: Store.counts,
): Digest.input => {
  let gems = digestGemsOf(finds, config.haulGemMinUsd)
  // Other items: finds below the gem threshold, plus each scene's own
  // otherCount — the same rule HaulStatus.build uses for the status reply.
  let otherFinds = Array.length(finds) - Array.length(gems)
  let otherFromScenes = Array.reduce(scenes, 0, (acc, s) => acc + s.otherCount->Option.getOr(0))
  {
    Digest.haulId: haul.haulId,
    name: haul.name,
    startedAt: haul.startedAt,
    costUsd: haul.costUsd,
    stopReason: haul.stopReason,
    gemMinUsd: config.haulGemMinUsd,
    gems,
    otherCount: otherFinds + otherFromScenes,
    valuedCount: counts.done,
    failed: digestFailedOf(scenes),
  }
}

let photoPathOf = (scenes: array<Store.scene>): Dict.t<string> => {
  let d = Dict.make()
  Array.forEach(scenes, s => Dict.set(d, s.sceneId, s.photoPath))
  d
}

// One inline image per distinct scene that holds a gem: a 480px-long-edge
// thumbnail made with Thumb.make, or the original photo when Thumb.make
// fails (a missing /usr/bin/sips, say). A scene whose photo is gone from
// disk is skipped rather than failing the whole digest.
let inlineImagesFor = (
  config: Config.t,
  gems: array<Digest.gem>,
  photoPaths: Dict.t<string>,
): array<Email.inlineImage> => {
  let seen = Dict.make()
  Array.filterMap(gems, g =>
    if Dict.get(seen, g.sceneId)->Option.isSome {
      None
    } else {
      Dict.set(seen, g.sceneId, true)
      switch Dict.get(photoPaths, g.sceneId) {
      | None => None
      | Some(photoPath) => {
          let thumbDir = Node.Path.join([config.dataDir, "thumbs"])
          Node.Fs.mkdirSync(thumbDir, {recursive: true})
          let thumbPath = Node.Path.join([thumbDir, g.sceneId ++ ".jpg"])
          let srcPath = switch Thumb.make(~src=photoPath, ~dest=thumbPath, ~longEdge=480) {
          | Ok() => thumbPath
          | Error(_) => photoPath
          }
          if Node.Fs.existsSync(srcPath) {
            Some({
              Email.cid: cidFor(g.sceneId),
              filename: g.sceneId ++ ".jpg",
              jpeg: Node.Fs.readFileBuffer(srcPath),
            })
          } else {
            None
          }
        }
      }
    }
  )
}

// Called once per drained haul (HaulWorker's own in-memory guard keeps it
// to once). A haulId with no matching row (shouldn't happen — checkDrained
// only calls this for a haul it just read) is a no-op.
let send = async (config: Config.t, store: Store.t, haulId: string): unit =>
  switch Store.getHaul(store, haulId) {
  | None => ()
  | Some(haul) => {
      let scenes = Store.scenesOf(store, haulId)
      let finds = Store.findsOf(store, haulId)
      let counts = Store.counts(store, haulId)
      let input = digestInputOf(config, haul, scenes, finds, counts)
      let images = inlineImagesFor(config, input.gems, photoPathOf(scenes))
      let digest = Digest.make(input, ~cidFor)
      let gmailUser = Config.getEnv("GMAIL_USER")
      let msg: Email.message = {
        to_: Config.getEnv("EMAIL_TO")->Option.getOr(gmailUser->Option.getOr("")),
        from_: gmailUser->Option.getOr("reflip@localhost"),
        date: Date.toUTCString(Date.make()),
        subject: digest.subject,
        text: digest.text,
        html: digest.html,
        images,
      }
      let boundary = "reflip-" ++ Node.Crypto.randomUUID()
      let mime = Email.buildMime(msg, ~boundary)
      let now = Date.toISOString(Date.make())
      let toOutbox = (note: string): unit => {
        Email.writeOutbox(~dir=outboxDir(config), ~haulId, ~mime)->ignore
        Store.markEmailed(store, ~haulId, ~now, ~note=Some(note))
      }
      if config.fixtures {
        toOutbox("written to " ++ outboxNoteName(haulId) ++ " because FIXTURES=1")
      } else {
        switch Email.credsFromEnv(Config.getEnv) {
        | Error(missing) =>
          toOutbox("written to " ++ outboxNoteName(haulId) ++ " because " ++ joinComma(missing) ++ " are not set")
        | Ok(creds) =>
          switch await Email.send(~transport=Email.gmailTransport(creds), ~creds, ~mime) {
          | Ok() => Store.markEmailed(store, ~haulId, ~now, ~note=Some("sent"))
          | Error(errMsg) => {
              Email.writeOutbox(~dir=outboxDir(config), ~haulId, ~mime)->ignore
              Store.markEmailed(
                store,
                ~haulId,
                ~now,
                ~note=Some("send failed: " ++ errMsg ++ ", written to " ++ outboxNoteName(haulId)),
              )
            }
          }
        }
      }
    }
  }
