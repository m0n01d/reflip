// Entry point. `npm start` runs this via:
//   node --env-file-if-exists=$HOME/.config/reflip/env src/Main.res.mjs

let config = Config.fromEnv()
let {Server.port: port} = Server.start(config)
Console.log(
  "reflip: listening on http://127.0.0.1:" ++
  Int.toString(port) ++
  " (fixtures=" ++ (config.fixtures ? "on" : "off") ++ ")",
)
