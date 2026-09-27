# Haul UI: build hand-off

This document is the build hand-off for the reflip Haul UI restyle. The design lives in a Design canvas, Version 3, published on 2026-09-26. It records Dwight's decisions, the new screen pieces, the data mapping, the motion list, the files to change, the order of work, and the checks before a PR.

## 1. Decisions

Dwight made these decisions on 2026-09-25 and 2026-09-26. Revision 2 of the design canvas already builds each one.

1. **No Scan/Haul switch during a haul.** Once a haul is open, the top of the screen shows only the wordmark. This matches today's app.
2. **Gems open in place.** A tap opens a gem inside the list, and a second tap closes it. Only one gem is open at a time, the same pattern as today. An open row shows:
   - the crop, with its box and the other gems' stickers
   - the size
   - the price, with the label "Claude's estimate"
   - the confidence dots
   - the where line
   - the eBay block: a range bar, or the text "No eBay stats"
   - the sold-prices button
3. **A failed Done retries on its own.** The retry must use the same delay tiers as a failed photo upload: 5, 15, then 60 seconds. There is no "Try again" button. Dwight said that this is an MVP, so the simplest build wins. If the auto-retry needs more than a few lines of code, skip it. Keep today's behavior. Restyle only the error line.
4. **Snap and Add photos stay on after a budget stop.** The stop banner adds one line: "Photos you add now are kept, but not valued."
5. **The quarter tip keeps its place.** It stays where it is today: while walking, under the ticket, before the gems. The words stay the same: "Put a quarter next to small items to show their size."

## 2. The design canvas

A new session cannot see this session's history. Read the canvas before you build.

1. Call the Artifact tool with action `read`, the url below, and path `project/Main.dc.html`.
2. Canvas url: `https://claude.ai/artifact/DMb4CwnCc34Nv4WvKnyjpb` (private to Dwight).
3. Each board except Main imports Main at one `moment` prop. Read Main.dc.html for the real markup, script, and styles.

The canvas has 11 boards, listed in `project/canvas.json`:

- `Main.dc.html` — Main (play me), the interactive board with every moment
- `Ready.dc.html` — Ready
- `FirstSnaps.dc.html` — First snaps · 4:12
- `GemsLanding.dc.html` — Gems landing · 18:36
- `Gem.dc.html` — Gem open · 19:40
- `Finishing.dc.html` — Finishing · 20:52
- `Done.dc.html` — Done · haul receipt
- `NoSignal.dc.html` — No signal · 20:40
- `Stopped.dc.html` — Stopped: budget reached
- `Failed.dc.html` — Failed photos, Done retrying
- `EbayBlock.dc.html` — eBay block: stats, no stats

A sticky note on the canvas gives the sample data: one store, 13 photos, 7 gems, at a cost of $1.82.

## 3. New pieces

Build these six pieces from Scan's existing parts. Nothing else on the Haul screen is new.

- **Photo tally.** One small tile per photo, in five states. Valued is solid ink. Valuing is an orange hatch that drifts. On phone is hollow, with a dashed ink outline. Not valued is hollow, with a solid ink outline and no hatch (a photo added after a budget stop). Failed is hollow, with a small ink x. Shape and lightness carry the meaning, not color alone.
- **Budget bar.** A track in the Scan timeline-bar style, labeled "budget". One notch marks each valued photo. The cost shows on the right, for example "$1.82 of $10.00".
- **Dock.** A bar at the bottom of the screen. Add photos sits on the left, in a round button. Snap sits in the center, in the large orange sticker button. Done sits on the right, in a black pill button.
- **Finishing bar.** When the user taps Done, the dock turns into a status bar. It shows a spinning ring and the text "Sending the last N photos…".
- **Haul receipt.** The Done screen turns the ticket into a receipt, in the Scan run-receipt style, with dotted leaders. A rotated ink stamp reads "HAULED", with the date.
- **eBay range bar.** A track that shows the eBay low-high range, a median tick, and Claude's estimate as an orange band.

## 4. Data mapping

The restyle needs no change to the API. It reads the same `counts` object that `GET /api/hauls/:id` returns today.

| Tile state | Data source |
|---|---|
| valued | `counts.valued` |
| valuing | `counts.queued + counts.running` |
| on phone | the length of the local queue (phone only) |
| failed | `counts.failed` |

After a stop (`stopReason` is set), the mapping changes for two states. Queued photos no longer count as valuing. They count as not valued instead. Valuing then equals `counts.running` alone.

## 5. Motion

The Main board on the canvas plays each motion. Turn every motion off under `prefers-reduced-motion`. The canvas uses a `still` flag for this.

1. The mode switch thumb slides between Scan and Haul. This shows only when no haul is open. There is no live dot and no pulse.
2. A Snap press squishes to scale 0.96. The dashed ring turns while a photo is on the phone or valuing, and during a failed Done retry. When no photo is on the phone or valuing, the ring stops.
3. A new photo tile drops into the tally hollow. It fills with a drifting hatch while valuing. When valued, it snaps to solid ink with a small pop.
4. A gem row opens with a grid-rows transition of about 250 ms. A second tap closes it the same way. Only one row opens at a time.
5. A landed gem slides its row in at its sorted place, with a peach flash that fades over about 1.2 seconds. Its number sticker pops in from -8 degrees, with a small overshoot. The hero number increases.
6. The budget fill eases. Each valued photo adds one notch.
7. On Done, the receipt prints downward over about 400 ms. Then the stamp lands, from scale 1.3 to scale 1.

## 6. Files to change

- `src/web/App.res` — the Haul render logic: `HaulView`, `GemCard`, the counts row, and the dock buttons.
- `src/web/AppState.res` — the model and the `msg` type for Haul, and the Done retry after `DoneFailed`. The "not valued" state comes from `counts` and `stopReason`, so it needs no new model field.
- `src/web/scan.css` — add every Haul class here.
- `public/app.css` — remove the Haul classes from this file. `scan.css` becomes the one style sheet for both modes.
- `src/web/ScanShell.res` — restyle the Haul Ready screen, which already renders here.
- `scripts/haul-smoke.mjs` — update its selectors and taps for the new markup.

## 7. Order of work

The Haul build waits for one merge first. Branch `claude/scan-ui-copy` closes the Scan UI design gaps (board card "close the scan UI design gaps"). It changes `scan.css` and `ScanShell.res`, the same files that this restyle changes.

If `claude/scan-ui-copy` is not in `main` yet, stop and tell Dwight. To find out, run `gh pr list --repo m0n01d/reflip --state merged --head claude/scan-ui-copy`.

Then run these commands, in order:

1. `git fetch origin`
2. `git checkout -b claude/haul-ui-build origin/main`
3. `git merge --no-edit claude/haul-scan-ui-alignment-501fe4`

## 8. Verification

Run these checks before you call the build done.

1. Run `npm test`. Every test must pass.
2. Run `node scripts/haul-smoke.mjs`. The script must exit with code 0.
3. Take a dev-browser screenshot of each state. Place it next to its canvas board for comparison.
4. Do a click-path audit: list each new control, what it must do, and the screenshot that proves it.
5. Open a PR with the screenshots, under the PR rules in `~/code/CLAUDE.md`.
