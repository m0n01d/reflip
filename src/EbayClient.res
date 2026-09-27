// eBay Browse API client: client-credentials token (cached until it
// expires), active-listing search, and the stats decode. Field names
// checked against ~/code/yard-sale/worker/ebay.ts and eBay's own docs (see
// reflip's CLAUDE.md, "eBay facts") on 2026-09-24.
//
// Hard design rule: eBay numbers never reach the model (CLAUDE.md rule 1).
// This module is never imported by ClaudeClient.res or SystemPrompt.res —
// GuardTest.res checks the built Claude request body for eBay fixture data.

type token = {accessToken: string, expiresAtMs: float}
let cached: ref<option<token>> = ref(None)

let fetchToken = async (~clientId: string, ~clientSecret: string) => {
  let fresh = switch cached.contents {
  | Some(t) if t.expiresAtMs > Date.now() => Some(t.accessToken)
  | _ => None
  }
  switch fresh {
  | Some(token) => Ok(token)
  | None => {
      let basic = Fetch.btoa(clientId ++ ":" ++ clientSecret)
      let headers = Dict.fromArray([
        ("Authorization", "Basic " ++ basic),
        ("Content-Type", "application/x-www-form-urlencoded"),
      ])
      let body =
        "grant_type=client_credentials&scope=" ++
        encodeURIComponent("https://api.ebay.com/oauth/api_scope")
      let resp = await Fetch.fetch(
        "https://api.ebay.com/identity/v1/oauth2/token",
        ~init={Fetch.method: "POST", headers, body},
      )
      if Fetch.ok(resp) {
        let json = await Fetch.json(resp)
        switch (Json.stringField(json, "access_token"), Json.floatField(json, "expires_in")) {
        | (Some(accessToken), Some(expiresIn)) => {
            cached := Some({accessToken, expiresAtMs: Date.now() +. (expiresIn -. 60.0) *. 1000.0})
            Ok(accessToken)
          }
        | _ => Error("eBay token response missing access_token or expires_in")
        }
      } else {
        Error("eBay token request failed with status " ++ Int.toString(Fetch.status(resp)))
      }
    }
  }
}

let search = async (~accessToken: string, ~query: string) => {
  let headers = Dict.fromArray([
    ("Authorization", "Bearer " ++ accessToken),
    ("X-EBAY-C-MARKETPLACE-ID", "EBAY_US"),
  ])
  let url =
    "https://api.ebay.com/buy/browse/v1/item_summary/search?q=" ++
    encodeURIComponent(query) ++ "&limit=50"
  let resp = await Fetch.fetch(url, ~init={Fetch.headers: headers})
  if Fetch.ok(resp) {
    Ok(await Fetch.json(resp))
  } else {
    Error("eBay search failed with status " ++ Int.toString(Fetch.status(resp)))
  }
}

// Prices are in itemSummaries[].price.value (a decimal string). These are
// active asking prices, never sold prices — CLAUDE.md's eBay facts.
let decodeStats = (searchJson: JSON.t): option<Types.ebayStats> =>
  switch Json.arrayField(searchJson, "itemSummaries") {
  | None => None
  | Some(items) =>
    Array.filterMap(items, item =>
      Json.field(item, "price")
      ->Option.flatMap(p => Json.stringField(p, "value"))
      ->Option.flatMap(Float.fromString)
    )->Stats.compute
  }

// A one-tap link to eBay's own sold-listing search. Dwight opens this
// himself; code never crawls it (CLAUDE.md's eBay facts: "a link is not a
// crawl").
let soldSearchUrl = (query: string): string =>
  "https://www.ebay.com/sch/i.html?_nkw=" ++ encodeURIComponent(query) ++ "&LH_Sold=1&LH_Complete=1"

// Fixture-mode search: reads tests/fixtures/ebay-search-<n>.json instead of
// calling the network.
let searchFixture = (fixturesDir: string, index: int): JSON.t => {
  let path = Node.Path.join([fixturesDir, "ebay-search-" ++ Int.toString(index) ++ ".json"])
  JSON.parseOrThrow(Node.Fs.readFileUtf8(path, "utf8"))
}

// One item's eBay merge: fixture mode reads tests/fixtures/ebay-search-<n>;
// real mode calls the Browse API. Missing eBay keys (non-fixture) mean the
// stats are None and the second element of the tuple says why. Moved here
// from Server.mergeEbay (docs/spec-haul-mode.md "Step 3: brain queue") so
// HaulWorker.res can call it too without a Server <-> HaulWorker cycle.
let statsFor = async (
  config: Config.t,
  index: int,
  item: Types.claudeItem,
): (option<Types.ebayStats>, option<string>) =>
  if config.fixtures {
    // Fixture mode has only as many ebay-search-<n>.json files as the
    // static test scene has items (0, 1, 2). A live-recorded fixture, or a
    // larger synthetic scene, can ask for an index past that -- give that
    // item no eBay data instead of letting readFileUtf8 throw ENOENT.
    let fixturePath =
      Node.Path.join([config.fixturesDir, "ebay-search-" ++ Int.toString(index) ++ ".json"])
    if Node.Fs.existsSync(fixturePath) {
      (decodeStats(searchFixture(config.fixturesDir, index)), None)
    } else {
      (None, None)
    }
  } else {
    switch (config.ebayClientId, config.ebayClientSecret) {
    | (Some(id), Some(secret)) =>
      switch await fetchToken(~clientId=id, ~clientSecret=secret) {
      | Ok(token) =>
        switch await search(~accessToken=token, ~query=item.query) {
        | Ok(json) => (decodeStats(json), None)
        | Error(msg) => (None, Some("eBay search failed: " ++ msg))
        }
      | Error(msg) => (None, Some("eBay auth failed: " ++ msg))
      }
    | _ => (None, Some("eBay stats disabled: set EBAY_CLIENT_ID and EBAY_CLIENT_SECRET"))
    }
  }
