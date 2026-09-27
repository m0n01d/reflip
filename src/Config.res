// Server configuration, sourced from the environment only (CLAUDE.md's hard
// design rule 3). Nothing in this file is a secret literal.

type t = {
  port: int,
  fixtures: bool,
  dataDir: string,
  fixturesDir: string,
  anthropicApiKey: option<string>,
  ebayClientId: option<string>,
  ebayClientSecret: option<string>,
  structuredOutput: bool,
  distIndexPath: string,
  distDir: string,
  // Haul mode (docs/spec-haul-mode.md "Step 3: brain queue").
  haulConcurrency: int,
  haulMaxUsd: float,
  haulGemMinUsd: float,
  // Tests only: send the Claude call to a local stub with a short timeout.
  // fromEnv leaves both unset, so ClaudeClient uses the real API and
  // ClaudeClient.timeoutMs.
  claudeUrl?: string,
  claudeTimeoutMs?: int,
  // Tests only: how long HaulWorker waits after a 429/529 before it retries.
  // fromEnv leaves this unset, so HaulWorker uses its own 30 s default.
  haulRetryMs?: int,
  // The fixture-mode stream replay speed multiplier (env
  // STREAM_FIXTURE_SPEED). Optional only so every other Config.t literal in
  // the test suite keeps compiling unchanged -- fromEnv below always sets
  // it, to a real value (default 1.0), so it is "tests only" in name alone.
  // FixtureReplay.safeSpeed applies the same "ignore 0 or less" rule again,
  // for a caller that builds a Config.t by hand.
  streamFixtureSpeed?: float,
}

let getEnv = (key: string): option<string> =>
  Dict.get(Node.Process.env, key)->Option.flatMap(v => v == "" ? None : Some(v))

let fromEnv = (): t => {
  let cwd = Node.Process.cwd()
  {
    port: getEnv("PORT")->Option.flatMap(s => Int.fromString(s))->Option.getOr(8787),
    fixtures: getEnv("FIXTURES")->Option.getOr("") == "1",
    dataDir: getEnv("DATA_DIR")->Option.getOr(Node.Path.join([cwd, "data"])),
    fixturesDir: getEnv("FIXTURES_DIR")->Option.getOr(Node.Path.join([cwd, "tests/fixtures"])),
    anthropicApiKey: getEnv("ANTHROPIC_API_KEY"),
    ebayClientId: getEnv("EBAY_CLIENT_ID"),
    ebayClientSecret: getEnv("EBAY_CLIENT_SECRET"),
    structuredOutput: getEnv("STRUCTURED_OUTPUT")->Option.getOr("") != "0",
    distIndexPath: Node.Path.join([cwd, "dist/index.html"]),
    distDir: Node.Path.join([cwd, "dist"]),
    haulConcurrency: getEnv("HAUL_CONCURRENCY")->Option.flatMap(s => Int.fromString(s))->Option.getOr(4),
    haulMaxUsd: getEnv("HAUL_MAX_USD")->Option.flatMap(Float.fromString)->Option.getOr(10.0),
    haulGemMinUsd: getEnv("HAUL_GEM_MIN_USD")->Option.flatMap(Float.fromString)->Option.getOr(20.0),
    streamFixtureSpeed: getEnv("STREAM_FIXTURE_SPEED")
      ->Option.flatMap(Float.fromString)
      ->Option.flatMap(v => v > 0.0 ? Some(v) : None)
      ->Option.getOr(1.0),
  }
}
