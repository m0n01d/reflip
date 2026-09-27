# Profit estimate: build hand-off

Working tree: /Users/dwight/code/reflip/.claude/worktrees/elegant-kapitsa-27683f
Branch: claude/profit-estimate (from dd77eeb)

Verification command: `npm test`

Spec: `docs/spec-profit.md`, sections "The math", "Shipping classes", "Shape", "MVP" (steps 1 and 2 only).

## Steps

- [ ] 1. `src/Profit.res` and `src/tests/ProfitTest.res`. A pure module, modeled on
      `src/Pricing.res`, with no Node imports. The `shipClass` type, its `toString` and
      `fromString`. The tax, fee and postage constants, each with its source in a comment. The
      `fee`, `postage`, `net` and `estimate` functions. Two test cases at tolerance 0.001, plus a
      `fromString` round trip. Register `ProfitTest.run()` in `src/tests/AllTests.res`.
- [ ] 2. Class and tag price through the schema, decode, reply, stream and ledger.
      `SystemPrompt.res`: add `shipClass` and `tagPriceUsd` to both item schemas, bump both
      prompt versions. `Types.res`: decode `shipClass` and `tagPriceUsd` on `claudeItem`, add
      `profit` to `replyItem` and to `haulGem`, encode both. Update every decoder that
      `resq refs` finds, including the stream item decoder and the haul worker. `Store.res`: add
      the four ledger columns and fill them on every write path. Keep `GuardTest.res` green: no
      eBay number and no paid price in a Claude request.

## Log

(attempts and errors go here)
