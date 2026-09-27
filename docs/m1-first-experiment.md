# The first M1 experiment

This record came from PR #3. On 2026-09-27 it moved here from CLAUDE.md, so that it does not load in every session. Since the run, main raised the Claude time limit to 180 s, and live eBay keys arrived on 2026-09-25.

Measured 2026-09-24 on a MacBook Pro (Mac17,2, Apple M5, macOS 27.0, Node 26.0.0), not on the Mac mini. The model was `claude-sonnet-5` at its default effort, with no eBay keys. dev-browser sent each photo through the page at `http://127.0.0.1:8787/`, so `Resize.res` scaled it to a long edge of 1568px.

The 10 photos are yard-sale and car-boot-sale scenes from Wikimedia Commons, not Dwight's own tables. Each one had a long edge of 1568px or more before the resize. `~/Pictures/reflip-m1/SOURCES.tsv` on that Mac lists the source page and the license of each photo. Dwight's own photos come next, as a second set of rows.

For this run, a local edit raised the Claude fetch timeout in `ClaudeClient.res` from 60 s to 300 s. Nobody committed that edit. With the 60 s timeout, the first scene failed with a 500, and 2 of the 10 scenes took more than 60 s.

| Photo | Items | Cost $ | Claude s | Input tokens | Output tokens | Searches | Search share | RTT s | Resize ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| s01 | 19 | 0.233 | 85.8 | 61,689 | 7,955 | 3 | 13% | 85.9 | 63 |
| s02 | 10 | 0.176 | 43.6 | 56,958 | 3,216 | 3 | 17% | 43.6 | 47 |
| s03 | 11 | 0.136 | 41.6 | 38,750 | 2,800 | 3 | 22% | 41.6 | 85 |
| s04 | 9 | 0.171 | 49.5 | 51,278 | 3,832 | 3 | 18% | 49.5 | 71 |
| s05 | 12 | 0.146 | 51.6 | 39,502 | 3,722 | 3 | 21% | 51.7 | 41 |
| s06 | 5 | 0.026 | 11.9 | 8,192 | 972 | 0 | 0% | 11.9 | 28 |
| s07 | 9 | 0.154 | 44.7 | 47,296 | 2,894 | 3 | 20% | 44.7 | 49 |
| s08 | 15 | 0.172 | 143.2 | 50,127 | 4,172 | 3 | 17% | 143.2 | 39 |
| s09 | 14 | 0.150 | 51.3 | 41,115 | 3,779 | 3 | 20% | 51.4 | 60 |
| s10 | 8 | 0.035 | 18.3 | 8,808 | 1,760 | 0 | 0% | 18.3 | 72 |
| Median | 10.5 | 0.152 | 47.1 | 44,206 | 3,469 | 3 | 18% | 47.1 | 54 |

Search share is `webSearches` × $0.01 ÷ cost, as the M1 spec defines it. The 10 scenes cost $1.40 in total. One more call timed out before the timeout edit. It is not in the log, and its cost is unknown.

The spec's proposed thresholds give these results on the medians:

- Search is 18% of the median cost by the spec's formula. That is less than half, so by that rule the two-pass search does not move up in Later.
- The formula counts only the $0.01 fee, but the search results also bill as input tokens. The 2 scenes with no search used about 8,500 input tokens. The 8 scenes with search used 38,750 to 61,689.
- If search causes that difference, search drives about two thirds of the cost of a median scene with search. This estimate comes from only 2 scenes with no search.
- The median scene cost $0.152 and took 47.1 s in Claude. Both are over the thresholds of $0.10 and 20 s. The next step is to measure a lower effort on Sonnet 5, before any change of model.

Input tokens were 50% to 65% of the cost of each scene, and no scene used the prompt cache. The round trip from the page was the Claude time plus less than 0.2 s.

The raw replies in `data/raw/` show no bad JSON. All 10 stopped with `end_turn` and parsed as valid JSON. No range was inverted or wider than 5 times its low end. The highest range was $120 to $300, for a wooden garden cart. Confidence was 0.20 to 0.60. Scene s01 used 7,955 output tokens for 19 items, close to the `max_tokens` limit of 8,192.
