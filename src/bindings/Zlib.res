// Typed binding for Node's zlib module -- just the one function
// FixtureReplay.res needs, to read a gzipped fixture recording
// (tests/fixtures/<base>.events.jsonl.gz) without shipping it uncompressed.
// Per CLAUDE.md's ReScript rules: a typed external for the part of the API
// we use, not a raw call.
@module("node:zlib") external gunzipSync: Node.Buffer.t => Node.Buffer.t = "gunzipSync"
