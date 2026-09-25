// `npm run email:check` — a login-only check of the Gmail SMTP transport
// (Email.verify never sends a message). Reads GMAIL_USER and
// GMAIL_APP_PASSWORD from the environment the same way `npm start` does
// (see package.json's "email:check" script, the same
// --env-file-if-exists=$HOME/.config/reflip/env flag as "start").
//
// This logs in to Gmail with Dwight's real app password, so nobody runs it
// automatically — the conductor asks him first (CLAUDE.md hard rule 3:
// secrets from the environment only, never in the repo or a log; this
// module never prints GMAIL_APP_PASSWORD or any value that contains it).

let joinComma = (parts: array<string>): string =>
  Array.reduceWithIndex(parts, "", (acc, part, i) => i == 0 ? part : acc ++ ", " ++ part)

let main = async (): unit =>
  switch Email.credsFromEnv(Config.getEnv) {
  | Error(missing) => {
      Console.log("missing: " ++ joinComma(missing))
      Node.Process.exit(1)
    }
  | Ok(creds) =>
    switch await Email.verify(~transport=Email.gmailTransport(creds)) {
    | Ok() => {
        Console.log("SMTP login ok for " ++ creds.user)
        Node.Process.exit(0)
      }
    | Error(errMsg) => {
        Console.log("SMTP login failed: " ++ errMsg)
        Node.Process.exit(1)
      }
    }
  }

main()->Promise.ignore
