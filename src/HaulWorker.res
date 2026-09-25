// The brain's in-process queue for haul mode. Runs at most
// `config.haulConcurrency` Claude calls at a time, across every open haul.
// Per docs/spec-haul-mode.md "The brain" and "Step 3: brain queue" in the
// build plan.
//
// Hard design rule: eBay numbers never reach the model (CLAUDE.md rule 1).
// This module calls ClaudeClient.call first, then EbayClient.statsFor, and
// only merges them after the Claude reply is already decided — the same
// order Server.handleScene uses.

type t = {
  config: Config.t,
  store: Store.t,
  // Called once per haul, when it drains (see `checkDrained` below). Step 3
  // only logs; step 6 wires the digest email.
  onDrained: string => promise<unit>,
  mutable running: int,
  // A global backoff: set past `now` after a 429/529, so `kick` leaves every
  // queued scene alone (of any haul) until it passes.
  mutable pausedUntil: float,
  // Consecutive Claude failures, per haulId. A 429/529 counts too. Reset to
  // 0 on that haul's next success.
  streaks: Dict.t<int>,
  // In-memory guard so a drained haul calls `onDrained` exactly once, even
  // though `checkDrained` runs after every scene and again from the `/done`
  // route.
  drainedHauls: Dict.t<bool>,
}

let defaultRetryMs = 30_000

let retryMsFor = (config: Config.t): int => config.haulRetryMs->Option.getOr(defaultRetryMs)

let make = (~config: Config.t, ~store: Store.t, ~onDrained: string => promise<unit>): t => {
  config,
  store,
  onDrained,
  running: 0,
  pausedUntil: 0.0,
  streaks: Dict.make(),
  drainedHauls: Dict.make(),
}

let streakFor = (t: t, haulId: string): int => Dict.get(t.streaks, haulId)->Option.getOr(0)

let bumpStreak = (t: t, haulId: string): int => {
  let next = streakFor(t, haulId) + 1
  Dict.set(t.streaks, haulId, next)
  next
}

let resetStreak = (t: t, haulId: string): unit => Dict.set(t.streaks, haulId, 0)

let failStreakLimit = 3

// A haul is drained once it has doneAt, has not yet been emailed, and has
// nothing left running: either the queue is empty, or the haul was stopped
// and its in-flight scenes have all finished. Calls onDrained at most once
// per haul (drainedHauls).
let checkDrained = (t: t, haulId: string): unit =>
  switch Store.getHaul(t.store, haulId) {
  | None => ()
  | Some(haul) =>
    switch haul.doneAt {
    | None => ()
    | Some(_) =>
      if haul.emailedAt == None && !(Dict.get(t.drainedHauls, haulId)->Option.getOr(false)) {
        let counts = Store.counts(t.store, haulId)
        let queueEmpty = counts.queued == 0 && counts.running == 0
        let stoppedAndSettled = haul.stopReason != None && counts.running == 0
        if queueEmpty || stoppedAndSettled {
          Dict.set(t.drainedHauls, haulId, true)
          t.onDrained(haulId)->Promise.ignore
        }
      }
    }
  }

let readPhotoBase64 = (photoPath: string): option<string> =>
  try {
    Some(Node.Fs.readFileBuffer(photoPath)->Node.Buffer.toStringWithEncoding("base64"))
  } catch {
  | JsExn(_) => None
  }

// Inserts one finds row per item. `where` and `category` stay None until
// the haul prompt (step 4); promptVersion is the scene prompt's constant
// until then too. Only items at or above the haul's gem threshold get an
// eBay lookup — the same threshold HaulStatus.res uses to pick gems.
let insertFinds = async (t: t, scene: Store.scene, decoded: ClaudeClient.decoded): unit => {
  let now = Date.toISOString(Date.make())
  let ebayResults = await Promise.all(
    Array.mapWithIndex(decoded.items, (item, i) =>
      item.estimateHighUsd >= t.config.haulGemMinUsd
        ? EbayClient.statsFor(t.config, i, item)
        : Promise.resolve((None, None))
    ),
  )
  Array.forEachWithIndex(decoded.items, (item, i) => {
    let (ebay, _note) = Array.getUnsafe(ebayResults, i)
    let ebayJson = ebay->Option.map(stats => JSON.stringify(Types.encodeEbayStats(stats)))
    Store.insertFind(
      t.store,
      {
        Store.findId: Node.Crypto.randomUUID(),
        sceneId: scene.sceneId,
        model: Shared.modelId(Shared.defaultModel),
        fixture: t.config.fixtures,
        name: item.name,
        query: item.query,
        where: item.where,
        estimateLowUsd: item.estimateLowUsd,
        estimateHighUsd: item.estimateHighUsd,
        confidence: item.confidence,
        category: None,
        promptVersion: SystemPrompt.haulPromptVersion,
        ebayJson,
        paidUsd: None,
        soldUsd: None,
        soldOn: None,
        soldWhere: None,
        createdAt: now,
        size: item.size,
      },
    )
  })
}

type outcome =
  | Success(float, float) // costUsd, claudeMs
  | RetryLater(string) // 429/529 — scene stays queued
  | Failed(string, option<float>, option<float>) // error, costUsd, claudeMs — everything else, including a missing photo; a cut-off reply is billed, so it carries its cost

let claudeErrorText = (err: ClaudeClient.callError): string =>
  switch err {
  | ClaudeClient.NoApiKey => "no ANTHROPIC_API_KEY set and FIXTURES is not 1"
  | ClaudeClient.HttpError(status, msg) =>
    "Claude request failed (" ++ Int.toString(status) ++ "): " ++ msg
  | ClaudeClient.Timeout(ms) =>
    "Claude took longer than " ++ Float.toString(Int.toFloat(ms) /. 1000.0) ++ " s"
  | ClaudeClient.DecodeFailed(_) => "could not decode Claude's reply"
  | ClaudeClient.CutOff(_) => "reply cut off"
  }

let runScene = async (t: t, scene: Store.scene): outcome =>
  switch readPhotoBase64(scene.photoPath) {
  | None => Failed("could not read photo: " ++ scene.photoPath, None, None)
  | Some(imageBase64) => {
      let model = Shared.modelId(Shared.defaultModel)
      let claudeStart = Date.now()
      switch await ClaudeClient.call(
        ~config=t.config,
        ~model,
        ~imageBase64,
        ~mode=ClaudeClient.Haul(t.config.haulGemMinUsd),
      ) {
      | Ok(decoded) => {
          let claudeMs = Date.now() -. claudeStart
          let costUsd = Pricing.usdCost(~model, ~usage=decoded.usage)
          await insertFinds(t, scene, decoded)
          Store.finishScene(
            t.store,
            ~sceneId=scene.sceneId,
            ~costUsd,
            ~claudeMs,
            ~otherCount=decoded.otherCount,
          )
          Success(costUsd, claudeMs)
        }
      | Error(ClaudeClient.HttpError(status, _) as err) if status == 429 || status == 529 =>
        RetryLater(claudeErrorText(err))
      | Error(ClaudeClient.CutOff(raw) as err) => {
          let claudeMs = Date.now() -. claudeStart
          let costUsd = Pricing.usdCost(~model, ~usage=ClaudeClient.usageOfResponse(raw))
          Failed(claudeErrorText(err), Some(costUsd), Some(claudeMs))
        }
      | Error(err) => Failed(claudeErrorText(err), None, None)
      }
    }
  }

// Adds a scene's Claude spend to the haul and stops the haul when the total
// reaches the budget. A cut-off (failed) scene is real spend too.
let addCostAndCheckBudget = (t: t, ~haulId: string, costUsd: float): unit => {
  let total = Store.addHaulCost(t.store, ~haulId, costUsd)
  if total >= t.config.haulMaxUsd {
    Store.stopHaul(
      t.store,
      ~haulId,
      ~reason="budget reached: $" ++
      Float.toFixed(total, ~digits=2) ++
      " of $" ++
      Float.toFixed(t.config.haulMaxUsd, ~digits=2),
    )
  }
}

let rec kick = (t: t): unit =>
  if t.running < t.config.haulConcurrency && Date.now() >= t.pausedUntil {
    switch Store.nextQueued(t.store) {
    | None => ()
    | Some(scene) => {
        Store.setStatus(t.store, ~sceneId=scene.sceneId, Store.Running)
        t.running = t.running + 1
        process(t, scene)->Promise.ignore
        kick(t)
      }
    }
  }

and process = async (t: t, scene: Store.scene): unit => {
  let outcome = try {
    await runScene(t, scene)
  } catch {
  | JsExn(e) => Failed(JsExn.message(e)->Option.getOr("unknown error"), None, None)
  }
  switch outcome {
  | Success(costUsd, _claudeMs) => {
      resetStreak(t, scene.haulId)
      addCostAndCheckBudget(t, ~haulId=scene.haulId, costUsd)
    }
  | RetryLater(msg) => {
      Store.setStatus(t.store, ~sceneId=scene.sceneId, Store.Queued)
      let streak = bumpStreak(t, scene.haulId)
      t.pausedUntil = Date.now() +. Int.toFloat(retryMsFor(t.config))
      if streak >= failStreakLimit {
        Store.stopHaul(
          t.store,
          ~haulId=scene.haulId,
          ~reason="stopped after 3 Claude failures in a row: " ++ msg,
        )
      } else {
        Node.Timer.setTimeout(() => kick(t), retryMsFor(t.config))
      }
    }
  | Failed(msg, costUsd, claudeMs) => {
      Store.failScene(t.store, ~sceneId=scene.sceneId, ~error=msg, ~costUsd, ~claudeMs)
      // The budget check runs first. stopHaul keeps the first reason, so when
      // one scene hits both limits, "budget reached" wins over the streak.
      costUsd->Option.forEach(usd => addCostAndCheckBudget(t, ~haulId=scene.haulId, usd))
      let streak = bumpStreak(t, scene.haulId)
      if streak >= failStreakLimit {
        Store.stopHaul(
          t.store,
          ~haulId=scene.haulId,
          ~reason="stopped after 3 Claude failures in a row: " ++ msg,
        )
      }
    }
  }
  t.running = t.running - 1
  checkDrained(t, scene.haulId)
  kick(t)
}
