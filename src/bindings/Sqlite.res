// Typed externals for node:sqlite's DatabaseSync. Per CLAUDE.md: no %raw, no
// %%raw, no Obj.magic, and no external that returns our own record types —
// a row comes back as JSON.t, decoded at the edge, same as Json.res.
//
// Search before bind, 2026-09-24: npm search "rescript sqlite" and
// "rescript node:sqlite" found no ReScript bindings, and no repo under
// ~/code binds DatabaseSync. node:sqlite runs on Node 26.0.0 with no flag,
// so these bindings are our own.

type t
type statement

// A bound parameter. node:sqlite's statement methods take variadic
// positional arguments of string, number or null (we never bind a bigint
// or a Buffer from Store.res).
@unboxed
type param =
  | Text(string)
  | Num(float)
  | @as(null) Null

type runResult = {changes: float, lastInsertRowid: float}

@new @module("node:sqlite") external make: string => t = "DatabaseSync"
@send external exec: (t, string) => unit = "exec"
@send external prepare: (t, string) => statement = "prepare"
@send external close: t => unit = "close"

@send @variadic external run: (statement, array<param>) => runResult = "run"
@send @variadic external getRaw: (statement, array<param>) => Nullable.t<JSON.t> = "get"
@send @variadic external all: (statement, array<param>) => array<JSON.t> = "all"

// `get` has no row: node:sqlite returns `undefined`, not `null`.
let get = (stmt: statement, params: array<param>): option<JSON.t> =>
  getRaw(stmt, params)->Nullable.toOption
