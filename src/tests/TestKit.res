// Minimal assertion kit over node:assert, mirroring dippa's
// src/tests/TestKit.res (see reflip's CLAUDE.md).

@module("node:assert") external assertOk: (bool, string) => unit = "ok"

let check = (name: string, cond: bool): unit => {
  assertOk(cond, name)
  Console.log("  ok - " ++ name)
}

let approx = (name: string, actual: float, expected: float, ~eps: float): unit =>
  check(name, Math.abs(actual -. expected) < eps)

let section = (name: string): unit => Console.log("# " ++ name)
