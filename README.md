# reflip

reflip is the brain behind Flip Scout, a personal tool that values items for resale. Send it one
photo, and it replies with each sellable item's name, a resale estimate from Claude, and matching
eBay active-listing stats. This repo holds Part A: the brain only, with fixtures and tests. Part B,
the phone page that calls it, and its screenshot, come in a later change.

## Run it

```sh
npm install
npm run build
npm test
FIXTURES=1 PORT=8787 npm start
```

With the server running, send it the sample photo from another shell:

```sh
curl -s -X POST --data-binary @tests/fixtures/table.jpg -H 'content-type: image/jpeg' http://127.0.0.1:8787/api/scene
```

See `CLAUDE.md` for the hard design rules, the pricing table, and how the secrets load.
