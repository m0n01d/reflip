// Entry point. `npm start` runs this via:
//   node --env-file-if-exists=$HOME/.config/reflip/env src/Main.res.mjs

let config = Config.fromEnv()

Server.start(config)
->Promise.then((result: Server.startResult) => {
    Console.log(
      "reflip: listening on http://127.0.0.1:" ++
      Int.toString(result.port) ++
      " (fixtures=" ++ (config.fixtures ? "on" : "off") ++ ")",
    )
    Promise.resolve()
  })
->Promise.ignore
