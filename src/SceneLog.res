// Append-only scene log plus the raw Claude response dump. `dataDir` is a
// config value, never hardcoded, so tests can point it at a temp directory.

let ensureDirs = (dataDir: string): unit => {
  Node.Fs.mkdirSync(dataDir, {recursive: true})
  Node.Fs.mkdirSync(Node.Path.join([dataDir, "raw"]), {recursive: true})
}

let appendLine = (dataDir: string, json: JSON.t): unit => {
  ensureDirs(dataDir)
  Node.Fs.appendFileSync(Node.Path.join([dataDir, "scenes.jsonl"]), JSON.stringify(json) ++ "\n")
}

let writeRaw = (dataDir: string, sceneId: string, json: JSON.t): string => {
  ensureDirs(dataDir)
  let path = Node.Path.join([dataDir, "raw", sceneId ++ ".json"])
  Node.Fs.writeFileSync(path, JSON.stringify(json))
  path
}
