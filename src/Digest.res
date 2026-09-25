// Pure function from the rows of one haul to the haul-done email's subject,
// HTML body and text body. No I/O, no Node imports — hand-computed by
// DigestTest.res. See docs/spec-haul-mode.md, "Gems" and "The digest and
// the email".

type gem = {
  name: string,
  where: option<string>,
  estimateLowUsd: float,
  estimateHighUsd: float,
  confidence: float,
  soldSearchUrl: string,
  sceneId: string,
  ebayMedianUsd: option<float>,
  size: string,
}

type failedPhoto = {sceneId: string, error: string}

type input = {
  haulId: string,
  name: option<string>,
  startedAt: string,
  costUsd: float,
  stopReason: option<string>,
  gemMinUsd: float,
  gems: array<gem>,
  otherCount: int,
  valuedCount: int,
  failed: array<failedPhoto>,
}

type t = {subject: string, html: string, text: string}

// -- small formatters -------------------------------------------------------

let usd = (n: float): string => "$" ++ Int.toString(Float.toInt(Math.round(n)))

let usdCents = (n: float): string => "$" ++ Float.toFixed(n, ~digits=2)

let pct = (c: float): string => Int.toString(Float.toInt(Math.round(c *. 100.0))) ++ "%"

// Concatenates an array of strings with no separator, without relying on an
// unverified Array.join in the ReScript 12 stdlib.
let concatAll = (parts: array<string>): string =>
  Array.reduceWithIndex(parts, "", (acc, part, _i) => acc ++ part)

// & first, so its own escape can't be re-escaped by the later replacements.
let escapeHtml = (s: string): string => {
  let len = String.length(s)
  let rec go = (i, acc) =>
    if i >= len {
      acc
    } else {
      let piece = switch String.charAt(s, i) {
      | "&" => "&amp;"
      | "<" => "&lt;"
      | ">" => "&gt;"
      | "\"" => "&quot;"
      | "'" => "&#39;"
      | other => other
      }
      go(i + 1, acc ++ piece)
    }
  go(0, "")
}

// -- sorting ------------------------------------------------------------

// Highest estimateLowUsd first; ties broken by estimateHighUsd, also highest
// first (docs/spec-haul-mode.md, "Gems").
let sortGems = (gems: array<gem>): array<gem> =>
  Array.toSorted(gems, (a, b) =>
    a.estimateLowUsd != b.estimateLowUsd
      ? Float.compare(b.estimateLowUsd, a.estimateLowUsd)
      : Float.compare(b.estimateHighUsd, a.estimateHighUsd)
  )

// -- subject --------------------------------------------------------------

let storeSuffix = (name: option<string>): string =>
  switch name {
  | Some(n) if n != "" => " (" ++ n ++ ")"
  | _ => ""
  }

// e.g. "reflip haul: 3 gems, best $35–$85 (Goodwill)". Sorted gems in, so
// the best gem is always the first element.
let subjectLine = (sortedGems: array<gem>, name: option<string>): string =>
  switch Array.length(sortedGems) {
  | 0 => "reflip haul: no gems" ++ storeSuffix(name)
  | n => {
      let best = Array.getUnsafe(sortedGems, 0)
      let word = n == 1 ? "gem" : "gems"
      "reflip haul: " ++
      Int.toString(n) ++
      " " ++
      word ++
      ", best " ++
      usd(best.estimateLowUsd) ++
      "–" ++
      usd(best.estimateHighUsd) ++
      storeSuffix(name)
    }
  }

// -- HTML body --------------------------------------------------------------

let gemHtml = (g: gem, cidFor: string => string): string => {
  let whereLine = switch g.where {
  | Some(w) if w != "" =>
    "<div style=\"margin:2px 0;color:#555555\">" ++ escapeHtml(w) ++ "</div>"
  | _ => ""
  }
  let ebayLine = switch g.ebayMedianUsd {
  | Some(m) => "<div style=\"margin:2px 0;color:#555555\">eBay median: " ++ usd(m) ++ "</div>"
  | None => ""
  }
  let sizeSuffix = g.size == "" ? "" : " (" ++ escapeHtml(g.size) ++ ")"
  "<div style=\"margin:0 0 20px 0;padding-bottom:16px;border-bottom:1px solid #dddddd\">" ++
  "<img src=\"cid:" ++
  cidFor(g.sceneId) ++
  "\" width=\"240\" style=\"display:block;width:240px;max-width:100%;height:auto;margin:0 0 8px 0\" alt=\"" ++
  escapeHtml(g.name) ++
  "\">" ++
  "<div style=\"font-weight:bold;font-size:16px;margin:0 0 4px 0\">" ++
  escapeHtml(g.name) ++
  sizeSuffix ++
  "</div>" ++
  "<div style=\"margin:2px 0\">" ++
  usd(g.estimateLowUsd) ++
  "–" ++
  usd(g.estimateHighUsd) ++
  "</div>" ++
  whereLine ++
  "<div style=\"margin:2px 0;color:#555555\">confidence: " ++
  pct(g.confidence) ++
  "</div>" ++
  ebayLine ++
  "<div style=\"margin:6px 0 0 0\"><a href=\"" ++
  escapeHtml(g.soldSearchUrl) ++
  "\">Sold listings</a></div>" ++
  "</div>"
}

let failedHtml = (failed: array<failedPhoto>): string =>
  if Array.length(failed) == 0 {
    ""
  } else {
    let items = concatAll(
      Array.map(failed, f =>
        "<li>" ++ escapeHtml(f.sceneId) ++ ": " ++ escapeHtml(f.error) ++ "</li>"
      ),
    )
    "<p style=\"margin:16px 0 4px 0\">Failed photos:</p>" ++
    "<ul style=\"margin:0 0 16px 0;padding-left:20px\">" ++
    items ++
    "</ul>"
  }

let stopHtml = (stopReason: option<string>): string =>
  switch stopReason {
  | Some(r) if r != "" =>
    "<p style=\"margin:16px 0 4px 0;color:#aa0000\">Haul stopped: " ++ escapeHtml(r) ++ "</p>"
  | _ => ""
  }

let htmlBody = (input: input, sortedGems: array<gem>, subject: string, ~cidFor: string => string): string => {
  let gemsSection = if Array.length(sortedGems) == 0 {
    "<p style=\"margin:0 0 16px 0\">No gems this haul.</p>"
  } else {
    concatAll(Array.map(sortedGems, g => gemHtml(g, cidFor)))
  }
  let otherWord = input.otherCount == 1 ? "item" : "items"
  let otherLine =
    "<p style=\"margin:16px 0 4px 0\">" ++
    Int.toString(input.otherCount) ++
    " other " ++
    otherWord ++
    " not listed.</p>"
  let footer =
    "<p style=\"margin:16px 0 0 0;color:#555555\">" ++
    Int.toString(input.valuedCount) ++
    " photos valued, cost " ++
    usdCents(input.costUsd) ++
    ".</p>"
  "<div style=\"font-family:sans-serif;color:#222222;max-width:480px;margin:0 auto\">" ++
  "<h1 style=\"font-size:18px;margin:0 0 16px 0\">" ++
  escapeHtml(subject) ++
  "</h1>" ++
  gemsSection ++
  otherLine ++
  failedHtml(input.failed) ++
  stopHtml(input.stopReason) ++
  footer ++
  "</div>"
}

// -- text body --------------------------------------------------------------

let gemText = (g: gem): string => {
  let whereLine = switch g.where {
  | Some(w) if w != "" => "  where: " ++ w ++ "\n"
  | _ => ""
  }
  let ebayLine = switch g.ebayMedianUsd {
  | Some(m) => "  eBay median: " ++ usd(m) ++ "\n"
  | None => ""
  }
  let sizeSuffix = g.size == "" ? "" : " (" ++ g.size ++ ")"
  g.name ++
  sizeSuffix ++
  "\n  " ++
  usd(g.estimateLowUsd) ++
  "–" ++
  usd(g.estimateHighUsd) ++
  "\n" ++
  whereLine ++
  "  confidence: " ++
  pct(g.confidence) ++
  "\n" ++
  ebayLine ++
  "  sold listings: " ++
  g.soldSearchUrl ++
  "\n\n"
}

let failedText = (failed: array<failedPhoto>): string =>
  if Array.length(failed) == 0 {
    ""
  } else {
    "Failed photos:\n" ++
    concatAll(Array.map(failed, f => "  " ++ f.sceneId ++ ": " ++ f.error ++ "\n"))
  }

let stopText = (stopReason: option<string>): string =>
  switch stopReason {
  | Some(r) if r != "" => "Haul stopped: " ++ r ++ "\n"
  | _ => ""
  }

let textBody = (input: input, sortedGems: array<gem>, subject: string): string => {
  let gemsSection = if Array.length(sortedGems) == 0 {
    "No gems this haul.\n\n"
  } else {
    concatAll(Array.map(sortedGems, gemText))
  }
  let otherWord = input.otherCount == 1 ? "item" : "items"
  subject ++
  "\n\n" ++
  gemsSection ++
  Int.toString(input.otherCount) ++
  " other " ++
  otherWord ++
  " not listed.\n" ++
  failedText(input.failed) ++
  stopText(input.stopReason) ++
  Int.toString(input.valuedCount) ++
  " photos valued, cost " ++
  usdCents(input.costUsd) ++
  ".\n"
}

// -- entry point --------------------------------------------------------------

let make = (input: input, ~cidFor: string => string): t => {
  let sorted = sortGems(input.gems)
  let subject = subjectLine(sorted, input.name)
  {
    subject,
    html: htmlBody(input, sorted, subject, ~cidFor),
    text: textBody(input, sorted, subject),
  }
}
