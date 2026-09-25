// HaulEmail.send, exercised through the whole haul flow: fixture mode never
// calls the network (FIXTURES=1 short-circuits both Claude and Email.send),
// so onDrained writes the digest straight to data/outbox and this test only
// reads that file back. Per docs/spec-haul-mode.md "The digest and the
// email" and the build plan's "Step 6: digest and email".

let cwd = Node.Process.cwd()
let fixturesDir = Node.Path.join([cwd, "tests/fixtures"])

let tmpDataDir = (): string =>
  Node.Path.join([Node.Os.tmpdir(), "reflip-haul-email-test-" ++ Node.Crypto.randomUUID()])

let sleep = (ms: int): promise<unit> =>
  Promise.make((resolve, _reject) => Node.Timer.setTimeout(() => resolve(), ms))

// Bounded poll, same shape as HaulTest.res's own — never loops forever.
let pollUntil = async (~timeoutMs: int, check: unit => promise<bool>): bool => {
  let deadline = Date.now() +. Int.toFloat(timeoutMs)
  let succeeded = ref(false)
  let keepGoing = ref(true)
  while keepGoing.contents {
    if await check() {
      succeeded := true
      keepGoing := false
    } else if Date.now() >= deadline {
      keepGoing := false
    } else {
      await sleep(100)
    }
  }
  succeeded.contents
}

let getJson = async (url: string): (int, JSON.t) => {
  let resp = await Fetch.fetch(url, ~init={Fetch.method: "GET"})
  (Fetch.status(resp), await Fetch.json(resp))
}

let postJson = async (url: string, body: JSON.t): (int, JSON.t) => {
  let resp = await Fetch.fetch(
    url,
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "application/json")]),
      body: JSON.stringify(body),
    },
  )
  (Fetch.status(resp), await Fetch.json(resp))
}

let postEmpty = async (url: string): int => {
  let resp = await Fetch.fetch(url, ~init={Fetch.method: "POST"})
  Fetch.status(resp)
}

let postScene = async (base: string, haulId: string, clientId: string): (int, JSON.t) => {
  let resp = await Fetch.fetch(
    base ++ "/api/hauls/" ++ haulId ++ "/scenes",
    ~init={
      Fetch.method: "POST",
      headers: Dict.fromArray([("content-type", "image/jpeg"), ("x-client-id", clientId)]),
      body: "fake-jpeg-bytes",
    },
  )
  (Fetch.status(resp), await Fetch.json(resp))
}

let countsOf = (statusJson: JSON.t): JSON.t =>
  Json.field(statusJson, "counts")->Option.getOr(Json.obj([]))

let valuedCount = (statusJson: JSON.t): option<int> => Json.intField(countsOf(statusJson), "valued")

let baseConfig = (~dataDir: string): Config.t => {
  Config.port: 0,
  fixtures: true,
  dataDir,
  fixturesDir,
  anthropicApiKey: None,
  ebayClientId: None,
  ebayClientSecret: None,
  structuredOutput: true,
  distIndexPath: Node.Path.join([cwd, "dist/index.html"]),
  distDir: Node.Path.join([cwd, "dist"]),
  haulConcurrency: 4,
  haulMaxUsd: 10.0,
  haulGemMinUsd: 20.0,
}

// -- tiny string helpers, test-local only (no regex, same style as
// EmailTest.res) ------------------------------------------------------------

let crlfLines = (s: string): array<string> => String.split(s, "\r\n")

let countOccurrences = (haystack: string, needle: string): int => {
  let hLen = String.length(haystack)
  let nLen = String.length(needle)
  let rec go = (i, acc) =>
    if i > hLen - nLen {
      acc
    } else if String.substring(haystack, ~start=i, ~end=i + nLen) == needle {
      go(i + nLen, acc + 1)
    } else {
      go(i + 1, acc)
    }
  nLen == 0 ? 0 : go(0, 0)
}

let run = async () => {
  TestKit.section("HaulEmail: fixture haul writes the digest to data/outbox")

  let dataDir = tmpDataDir()
  let config = baseConfig(~dataDir)
  let {Server.server, port, store} = await Server.start(config)
  let base = "http://127.0.0.1:" ++ Int.toString(port)

  let (_status, createJson) = await postJson(base ++ "/api/hauls", Json.obj([("name", Json.str("Estate Sale"))]))
  let haulId = Json.stringField(createJson, "haulId")->Option.getOr("")
  TestKit.check("the haul was created", haulId != "")

  let (s1, j1) = await postScene(base, haulId, "client-a")
  TestKit.check("first scene 202", s1 == 202)
  let sceneId1 = Json.stringField(j1, "sceneId")->Option.getOr("")

  let (s2, j2) = await postScene(base, haulId, "client-b")
  TestKit.check("second scene 202", s2 == 202)
  let sceneId2 = Json.stringField(j2, "sceneId")->Option.getOr("")

  let reachedValued2 = await pollUntil(~timeoutMs=5000, async () => {
    let (_status, json) = await getJson(base ++ "/api/hauls/" ++ haulId)
    valuedCount(json) == Some(2)
  })
  TestKit.check("both scenes reach valued within 5 s", reachedValued2)

  let doneStatus = await postEmpty(base ++ "/api/hauls/" ++ haulId ++ "/done")
  TestKit.check("POST done responds 200", doneStatus == 200)

  let emailed = await pollUntil(~timeoutMs=5000, async () => {
    let (_status, json) = await getJson(base ++ "/api/hauls/" ++ haulId)
    Json.stringField(json, "emailedAt")->Option.isSome
  })
  TestKit.check("the haul is marked emailed within 5 s of done", emailed)

  let (_status, finalJson) = await getJson(base ++ "/api/hauls/" ++ haulId)
  let emailNote = Json.stringField(finalJson, "emailNote")->Option.getOr("")
  TestKit.check(
    "the emailNote says why it went to the outbox instead of Gmail",
    emailNote == "written to data/outbox/" ++ haulId ++ ".eml because FIXTURES=1",
  )

  let emlPath = Node.Path.join([dataDir, "outbox", haulId ++ ".eml"])
  TestKit.check("the .eml file exists in data/outbox", Node.Fs.existsSync(emlPath))

  let eml = Node.Fs.readFileUtf8(emlPath, "utf8")
  let lines = crlfLines(eml)

  // -- subject: an RFC 2047 UTF-8 encoded word, per Email.buildMime.
  let subjectLine =
    Array.filterMap(lines, l => String.startsWith(l, "Subject: ") ? Some(l) : None)->Array.get(0)
  switch subjectLine {
  | None => TestKit.check("a Subject header line exists", false)
  | Some(line) => {
      let encoded = String.substring(line, ~start=String.length("Subject: "), ~end=String.length(line))
      TestKit.check(
        "the subject is an RFC 2047 UTF-8 base64 encoded word",
        String.startsWith(encoded, "=?UTF-8?B?") && String.endsWith(encoded, "?="),
      )
    }
  }

  // -- exactly one Content-ID per gem scene: both scenes have gems (the haul
  // fixture puts 2 items above the $20 default per scene), and
  // HaulEmail.inlineImagesFor dedups by sceneId, so 2 scenes give exactly 2
  // Content-IDs, one per scene.
  TestKit.check(
    "the first scene's Content-ID is present",
    String.includes(eml, "Content-ID: <scene-" ++ sceneId1 ++ "@reflip>"),
  )
  TestKit.check(
    "the second scene's Content-ID is present",
    String.includes(eml, "Content-ID: <scene-" ++ sceneId2 ++ "@reflip>"),
  )
  TestKit.check(
    "exactly 2 inline images, one per gem scene",
    countOccurrences(eml, "Content-ID: <") == 2,
  )
  TestKit.check(
    "each inline image is an inline image/jpeg part",
    countOccurrences(eml, "Content-Type: image/jpeg") == 2,
  )

  // -- a text part and an html part, per the multipart/alternative Email.res
  // builds.
  TestKit.check("the .eml has a text/plain part", String.includes(eml, "Content-Type: text/plain; charset=UTF-8"))
  TestKit.check("the .eml has a text/html part", String.includes(eml, "Content-Type: text/html; charset=UTF-8"))

  Node.HttpServer.close(server, () => ())
  Store.close(store)
}
