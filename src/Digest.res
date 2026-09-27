// Pure function from the rows of one haul to the haul-done email's subject,
// HTML body and text body. No I/O, no Node imports — hand-computed by
// DigestTest.res. See docs/spec-haul-mode.md, "Gems" and "The digest and
// the email".

type gemCrop = {
  cid: string,
  width: int,
  height: int,
}

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
  // This gem's box crop: its mail Content-ID and its real pixel size, e.g.
  // cid "gem-<sceneId>-<n>@reflip" (HaulEmail.gemCidFor). None when the
  // find has no box, or when the crop itself failed to build — either
  // way the card shows "no box" text and adds no image.
  crop: option<gemCrop>,
  // This gem's profit estimate — the net at each end of the range, and
  // the profit at each end if there is a tag price (Profit.netText,
  // Profit.profitText). None only if a caller could not compute one; every
  // real find can, so HaulEmail.digestGemsOf always fills it.
  profit: option<Profit.estimate>,
}

type failedPhoto = {sceneId: string, error: string}

// One photo (scene) that has at least one gem: its full-photo image is
// cidFor(sceneId), and its gems are in sortGems order. A photo with no
// gems never becomes a section — see `sections` below.
type section = {
  sceneId: string,
  gems: array<gem>,
}

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

// -- grouping by photo --------------------------------------------------------------

// Groups sortedGems by sceneId. A section's rank is its first gem's rank in
// sortedGems (the first sceneId seen becomes the first section), and each
// section's own gems stay in sortedGems order too — one pass, in order, is
// enough for both. A photo that owns no gem never appears: there is nothing
// in `gems` to put it there.
let sections = (sortedGems: array<gem>): array<section> => {
  let order: array<string> = []
  let bySceneId: Dict.t<array<gem>> = Dict.make()
  Array.forEach(sortedGems, g =>
    switch Dict.get(bySceneId, g.sceneId) {
    | Some(existing) => Array.push(existing, g)
    | None => {
        Dict.set(bySceneId, g.sceneId, [g])
        Array.push(order, g.sceneId)
      }
    }
  )
  Array.map(order, sceneId => {sceneId, gems: Dict.get(bySceneId, sceneId)->Option.getOr([])})
}

// e.g. "Photo 2 · 3 gems". `n` is the section's 1-based position in the
// sections array (its display order), not a scene-capture index — Digest
// never sees the full list of photos, only the ones with a gem.
let sectionHeading = (n: int, gemCount: int): string => {
  let word = gemCount == 1 ? "gem" : "gems"
  "Photo " ++ Int.toString(n) ++ " · " ++ Int.toString(gemCount) ++ " " ++ word
}

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

// One gem's card: its box crop (or "no box" when there is none), then name,
// range, where, confidence, eBay line and sold link — same text and
// escaping as before, just without the whole-photo image (the section now
// carries that once, above every card).
let gemHtml = (g: gem): string => {
  let cropHtml = switch g.crop {
  | Some(crop) =>
    "<img src=\"cid:" ++
    crop.cid ++
    "\" width=\"" ++
    Int.toString(crop.width) ++
    "\" height=\"" ++
    Int.toString(crop.height) ++
    "\" style=\"display:block;max-width:100%;height:auto;margin:0 0 8px 0\" alt=\"" ++
    escapeHtml(g.name) ++
    "\">"
  | None =>
    "<div style=\"margin:0 0 8px 0;color:#888888;font-style:italic\">no box</div>"
  }
  let whereLine = switch g.where {
  | Some(w) if w != "" =>
    "<div style=\"margin:2px 0;color:#555555\">" ++ escapeHtml(w) ++ "</div>"
  | _ => ""
  }
  let ebayLine = switch g.ebayMedianUsd {
  | Some(m) => "<div style=\"margin:2px 0;color:#555555\">eBay median: " ++ usd(m) ++ "</div>"
  | None => ""
  }
  // Red only when it is a loss (Profit.isLoss); email HTML takes inline
  // styles only, so the color is hard-coded here rather than in a class.
  let profitLine = switch g.profit {
  | Some(p) =>
    let style = Profit.isLoss(p) ? "margin:2px 0;color:#cc0000" : "margin:2px 0;color:#555555"
    "<div style=\"" ++ style ++ "\">" ++ Profit.lineText(p) ++ "</div>"
  | None => ""
  }
  let sizeSuffix = g.size == "" ? "" : " (" ++ escapeHtml(g.size) ++ ")"
  "<div style=\"margin:0 0 20px 0;padding-bottom:16px;border-bottom:1px solid #dddddd\">" ++
  cropHtml ++
  "<div style=\"font-weight:bold;font-size:16px;margin:0 0 4px 0\">" ++
  escapeHtml(g.name) ++
  sizeSuffix ++
  "</div>" ++
  "<div style=\"margin:2px 0\">" ++
  usd(g.estimateLowUsd) ++
  "–" ++
  usd(g.estimateHighUsd) ++
  "</div>" ++
  profitLine ++
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

// One photo section: a heading, the full photo once, then one card per
// gem, in that order.
let sectionHtml = (n: int, s: section, ~cidFor: string => string): string => {
  let heading = sectionHeading(n, Array.length(s.gems))
  let photoHtml =
    "<img src=\"cid:" ++
    cidFor(s.sceneId) ++
    "\" width=\"100%\" style=\"display:block;width:100%;max-width:640px;height:auto;margin:0 0 12px 0\" alt=\"" ++
    escapeHtml(heading) ++
    "\">"
  "<div style=\"margin:0 0 28px 0\">" ++
  "<h2 style=\"font-size:15px;margin:0 0 8px 0;color:#333333\">" ++
  escapeHtml(heading) ++
  "</h2>" ++
  photoHtml ++
  concatAll(Array.map(s.gems, gemHtml)) ++
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
    concatAll(Array.mapWithIndex(sections(sortedGems), (s, i) => sectionHtml(i + 1, s, ~cidFor)))
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
  let profitLine = switch g.profit {
  | Some(p) => "  " ++ Profit.lineText(p) ++ "\n"
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
  profitLine ++
  whereLine ++
  "  confidence: " ++
  pct(g.confidence) ++
  "\n" ++
  ebayLine ++
  "  sold listings: " ++
  g.soldSearchUrl ++
  "\n\n"
}

// One photo section: a heading line, then its gems, no image lines (the
// text body never had any).
let sectionText = (n: int, s: section): string =>
  sectionHeading(n, Array.length(s.gems)) ++ "\n" ++ concatAll(Array.map(s.gems, gemText))

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
    concatAll(Array.mapWithIndex(sections(sortedGems), (s, i) => sectionText(i + 1, s)))
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
