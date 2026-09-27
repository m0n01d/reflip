# Haul UI design boards

These files are a copy of the Design canvas at
https://claude.ai/artifact/DMb4CwnCc34Nv4WvKnyjpb (private to Dwight), version 1790400214-43c9,
copied on 2026-09-26. The build hand-off is `docs/haul-ui.md`.

`Main.dc.html` holds the markup, the CSS and the component logic for every moment of a haul.
Each other `.dc.html` file shows `Main` at one moment. `EbayBlock.dc.html` is the eBay block of an
open gem, with stats and without stats.

The Design runtime and the table photo are not in this repo. To render the boards again, serve
this folder with the runtime saved as `support.js`, and put the photo at
`/_blob/be38a67f4b37d98c862a8a275b4e27c0`. The runtime is `artifact-type/dc-runtime.js` in the
artifact.
