// Typed binding for node:child_process's execFileSync, used by Thumb.res to
// shell out to /usr/bin/sips. Per CLAUDE.md's ReScript rules: no %raw, no
// Obj.magic. A missing binary or a non-zero exit makes execFileSync throw; a
// caller catches that with ReScript's `JsExn` pattern (see ClaudeClient.res
// for the same idiom), never with %raw or a cast.

type options = {encoding: string}

@module("node:child_process")
external execFileSync: (string, array<string>, options) => string = "execFileSync"
