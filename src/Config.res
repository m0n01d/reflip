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
  // Tests only: send the Claude call to a local stub with a short timeout.
  // fromEnv leaves both unset, so ClaudeClient uses the real API and
  // ClaudeClient.timeoutMs.
  claudeUrl?: string,
  claudeTimeoutMs?: int,
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
  }
}
