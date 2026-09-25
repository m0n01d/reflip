# Fixtures

These files are synthetic. Nobody captured them from a real call.

We shaped `claude-scene.json` from the Messages API, per the claude-api
skill. We shaped each `ebay-search-*.json` from the eBay Browse API, per
`~/code/yard-sale/worker/ebay.ts` and eBay's own docs. `table.jpg` is a
small generated image, not a real photo. We shaped `claude-stream.sse`
by hand from the streaming Messages API docs. It embeds the same 3
items as `claude-scene.json`, and nobody streamed it from a real call.
