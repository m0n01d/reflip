// One-shot recorder for the spot pass's real shape: a single live,
// toolless Claude call over one fixed photo, recorded as {ms, event,
// data} SSE lines. `npm run spike:spot` runs this and writes
// docs/stream-spike/events/spot-1.events.jsonl, which is gzipped by hand
// afterward (the same way box-last-1 and box-second-1 were made) to
// docs/stream-spike/events/spot-1.events.jsonl.gz.
//
// This is not StreamSpike.res, and does not import from it: StreamSpike's
// CLI, and its schema/search/box-position variants, are all priced-pass
// concerns the spot pass does not have (no tools, one fixed prompt).
//
// docs/scan-ui.md brief, item 4: one live call, under $0.05. Never a
// priced live call from this file — only SpotPass.run. Safe to re-run:
// once docs/stream-spike/events/spot-1.events.jsonl(.gz) exists, `main`
// skips the live call and only re-runs the match/report step below,
// reading both recordings back from disk.

let photoPath = "/Users/dwight/code/reflip/.claude/worktrees/admiring-kirch-eef695/data/boxes/s01-1568-sent.jpg"
let outDir = "docs/stream-spike/events"
let outPath = "docs/stream-spike/events/spot-1.events.jsonl"
let priceFixturePath = "docs/stream-spike/events/box-second-1.events.jsonl.gz"

let eventLine = (ms: float, sseEvt: Sse.event): string =>
  JSON.stringify(
    Json.obj([
      ("ms", Json.num(ms)),
      ("event", Json.str(sseEvt.event)),
      ("data", Json.str(sseEvt.data)),
    ]),
  )

// The live call. Runs once: `main` below only calls this when neither
// outPath nor its gzipped form exists yet.
let recordLive = async (~width: int, ~height: int, ~imageBase64: string): unit => {
  let config = Config.fromEnv()
  let model = Pricing.defaultModel

  Node.Fs.mkdirSync(outDir, {recursive: true})
  Node.Fs.writeFileSync(outPath, "")

  let controller = Fetch.AbortController.make()
  let onRaw = (ms: float, sseEvt: Sse.event): unit =>
    Node.Fs.appendFileSync(outPath, eventLine(ms, sseEvt) ++ "\n")

  let outcome = await SpotPass.run(
    ~config,
    ~buildBody=(~structuredOutput) =>
      SpotPass.buildRequestBody(~model, ~imageBase64, ~structuredOutput, ~width, ~height),
    ~stop=Fetch.AbortController.signal(controller),
    ~onEvent=(_ms, _evt) => (),
    ~onRaw,
  )

  let outcomeTag = switch outcome {
  | SpotPass.Completed(_) => "completed"
  | SpotPass.Stopped(_) => "stopped"
  | SpotPass.TimedOut(_, _) => "timed_out"
  | SpotPass.HttpFailed(status, text) => "http_failed " ++ Int.toString(status) ++ " " ++ text
  | SpotPass.NoApiKey => "no_api_key"
  | SpotPass.NoFixture(msg) => "no_fixture " ++ msg
  }
  Console.log("outcome: " ++ outcomeTag)
  Console.log("events written to: " ++ outPath)
}

// Replays a recorded {ms, event, data} log through SpotPass's own model,
// the same way SceneStreamTest.res replays a priced fixture through
// SceneStream — so the reported numbers come from the same decode path
// production traffic uses, not from a second, separate parser.

let replaySpotWithTiming = (
  path: string,
): (array<(string, array<int>)>, Types.usage, option<float>) => {
  let events = FixtureReplay.readEvents(path)
  let items: ref<array<(string, array<int>)>> = ref([])
  let firstItemMs = ref(None)
  let (finalModel, _) = Array.reduce(events, (SpotPass.init, []), ((m, acc), recEvt) =>
    switch ClaudeEvents.decode(recEvt.evt) {
    | Ok(decoded) =>
      let (m2, logs) = SpotPass.update(m, decoded)
      Array.forEach(logs, log =>
        switch log {
        | SpotPass.ItemFound({name, box}) => {
            if firstItemMs.contents == None {
              firstItemMs := Some(recEvt.ms)
            }
            items := Array.concat(items.contents, [(name, box)])
          }
        | _ => ()
        }
      )
      (m2, Array.concat(acc, logs))
    | Error(_) => (m, acc)
    }
  )
  (items.contents, finalModel.usage, firstItemMs.contents)
}

// Replays box-second-1's priced fixture through SceneStream, the same
// pattern SceneStreamTest.res uses, to get its items' final boxes.
let replayPriced = (path: string): array<Types.claudeItem> => {
  let events = FixtureReplay.readEvents(path)
  let (finalModel, _) = Array.reduce(events, (SceneStream.init, []), ((m, acc), recEvt) =>
    switch ClaudeEvents.decode(recEvt.evt) {
    | Ok(decoded) =>
      let (m2, logs) = SceneStream.update(m, SceneStream.Event(decoded))
      (m2, Array.concat(acc, logs))
    | Error(_) => (m, acc)
    }
  )
  SceneStream.items(finalModel)
}

// Prints the spot-1 numbers the brief asks for, and matches each spot box
// against box-second-1's final priced item boxes with Overlap.bestMatch
// at 0.5 (docs/scan-ui.md brief, item 4). Both sides go through
// Box.decode with the same photo size, so the comparison is apples to
// apples. Assumes box-second-1 was also recorded at Shared.defaultModel
// (StreamSpike's own default): Sonnet 5 and Opus 5.5 share the same
// "high" resize tier, and this exact photo (1568x1176) is already under
// that tier's limit, so neither side actually rescales — only the clamp
// step can do anything here.
let report = (~width: int, ~height: int, ~recordedPath: string): unit => {
  let (spotItems, usage, firstItemMs) = replaySpotWithTiming(recordedPath)
  let usd = Pricing.usdCost(~model=Pricing.defaultModel, ~usage)

  Console.log("photo: " ++ photoPath ++ " (" ++ Int.toString(width) ++ "x" ++ Int.toString(height) ++ ")")
  Console.log(
    "first spot-item: " ++
    switch firstItemMs {
    | Some(ms) => Float.toString(ms) ++ " ms"
    | None => "(none)"
    },
  )
  Console.log("item count: " ++ Int.toString(Array.length(spotItems)))
  Console.log("input tokens: " ++ Int.toString(usage.inputTokens))
  Console.log("output tokens: " ++ Int.toString(usage.outputTokens))
  Console.log("usd: " ++ Float.toString(usd))

  if !Node.Fs.existsSync(priceFixturePath) {
    Console.log("no box-second-1 fixture found at " ++ priceFixturePath ++ ", skipping the match step")
  } else {
    let pricedItems = replayPriced(priceFixturePath)
    let pricedBoxes: array<(int, Types.box)> =
      pricedItems
      ->Array.mapWithIndex((item, i) => (i, item.box))
      ->Array.filterMap(((i, rawBox)) =>
        Box.decode(rawBox, ~sentWidth=width, ~sentHeight=height, ~model=Shared.defaultModel)->Option.map(
          box => (i, box),
        )
      )

    let spotBoxes: array<Types.box> =
      spotItems->Array.filterMap(((_, box)) =>
        Box.decode(
          Some(Array.map(box, Int.toFloat)),
          ~sentWidth=width,
          ~sentHeight=height,
          ~model=Shared.defaultModel,
        )
      )

    let ious: array<float> = spotBoxes->Array.filterMap(box =>
      switch Overlap.bestMatch(~box, ~candidates=pricedBoxes, ~threshold=0.5) {
      | None => None
      | Some(idx) =>
        switch Array.find(pricedBoxes, ((i, _)) => i == idx) {
        | Some((_, pricedBox)) => Some(Overlap.iou(box, pricedBox))
        | None => None
        }
      }
    )
    let sorted = Array.toSorted(ious, (a, b) => Float.compare(a, b))
    let medianIou = Array.length(sorted) == 0 ? 0.0 : Stats.percentile(sorted, 0.5)

    Console.log(
      "matched " ++
      Int.toString(Array.length(ious)) ++
      " of " ++
      Int.toString(Array.length(spotBoxes)) ++
      " spot boxes at IoU >= 0.5 against box-second-1's " ++
      Int.toString(Array.length(pricedBoxes)) ++
      " priced boxes",
    )
    Console.log("median IoU (matched pairs): " ++ Float.toString(medianIou))
  }
}

let main = async (): unit => {
  let gzPath = outPath ++ ".gz"
  let alreadyRecorded = Node.Fs.existsSync(gzPath) || Node.Fs.existsSync(outPath)
  if !Node.Fs.existsSync(photoPath) {
    Console.log("error: photo not found: " ++ photoPath)
    Node.Process.exit(1)
  } else {
    let buf = Node.Fs.readFileBuffer(photoPath)
    switch JpegSize.dimensions(buf) {
    | None => {
        Console.log("error: could not read JPEG dimensions from: " ++ photoPath)
        Node.Process.exit(1)
      }
    | Some((width, height)) => {
        if alreadyRecorded {
          Console.log(
            "spot-1 events already recorded (" ++
            (Node.Fs.existsSync(gzPath) ? gzPath : outPath) ++
            "), skipping the live call",
          )
        } else {
          let imageBase64 = Node.Buffer.toStringWithEncoding(buf, "base64")
          await recordLive(~width, ~height, ~imageBase64)
        }
        let recordedPath = Node.Fs.existsSync(gzPath) ? gzPath : outPath
        report(~width, ~height, ~recordedPath)
      }
    }
  }
}

main()->Promise.ignore
