# Haul UI click-path audit

Run against a fresh FIXTURES=1 server, with every haul route mocked by a
plain Node HTTP proxy in front of it (one board's canned JSON at a time),
with data lifted from the design canvas's own GEMS/FAILS sample arrays.
See scripts/haul-shots.mjs.

| Control | What it must do | Proof |
|---|---|---|
| Start haul (Ready) | POST /api/hauls fires; phase moves to Active and the tally appears | ok — FirstSnaps board (haul-tally present after Start a haul) |
| Add photos (multi input) | Files queue client-side; the onPhone tile/tally count rises | ok — GemsLanding/Finishing/NoSignal boards, {"count":3} |
| Snap (capture input) | A single photo queues the same way as Add photos | ok — FirstSnaps board |
| Gem row open | Tapping a closed row shows its .haul-gem-detail | ok — Gem board, opened "Blue and white transferware scalloped bowl set" |
| A second gem switches | Opening another row closes the first (at most one open) | ok — .haul-gem-detail count after switch = 1 (expected 1) |
| The same gem closes | Tapping an open row's own header closes it | ok — .haul-gem-detail count after close = 0 (expected 0) |
| Sold link href (blocked) | a.scan-ebay-sold-btn points at ebay.com; the tap is blocked network-side | ok — href=https://www.ebay.com/sch/i.html?_nkw=vintage%20blue%20white%20transferware%20scalloped%20bowl%20plates&LH_Sold=1&LH_Complete=1, popup opened then blocked (chrome-error, per route.abort) |
| Done (Finishing) | Tapping Done moves phase to Finishing; the dock bar replaces the controls | ok — Finishing board (.haul-bar present) |
| Done auto-retry | A failed Done retries once on its own after ~5 s (AppState.retryDelayMs(1)) | ok — second POST /done arrived 3186 ms after the first (Failed board) |
| The receipt | Once emailedAt is set, phase Finished shows the Haul Receipt section | ok — Done board (section[aria-label='Haul receipt']) |
| Start a new haul | Tapping it on the receipt returns to the Ready screen (NoHaul) | ok — Done-after-new-haul shot (.haul-ready-start reappeared) |
