// Typed externals for nodemailer (added to send the haul digest through
// Gmail SMTP with an app password — Email.res — instead of the OAuth Gmail
// API it replaces; Dwight has a Gmail app password and no OAuth keys,
// 2026-09-25). Per CLAUDE.md's ReScript rules: no %raw, no Obj.magic, no
// untyped externals.
//
// `createTransport` and `createStreamTransport` both bind nodemailer's one
// JS `createTransport` function, each with the options shape its caller
// actually passes — the same "same underlying function, two typed views"
// idiom Node.res uses for `readFileSync` (`readFileBuffer` / `readFileUtf8`).
// The real Gmail connection uses `createTransport`; EmailTest.res's
// network-free stub uses `createStreamTransport`, nodemailer's
// StreamTransport, which buffers the raw MIME message instead of opening a
// socket.
//
// `sendMail`'s reply is typed twice for the same reason. `sendMail` decodes
// it as JSON.t, per CLAUDE.md's "type each value from outside the program
// as JSON.t and decode it at the edge" — Email.res only ever reads its
// `rejected` field. `sendMailStream` types the exact shape nodemailer's
// StreamTransport resolves with, `{envelope, message}` — verified against
// node_modules/nodemailer/dist/cjs/stream-transport/index.js (nodemailer
// 10.0.10) on 2026-09-25 — so EmailTest.res can read the buffered raw
// message back as a real Buffer, with no cast.

type auth = {user: string, pass: string}

type smtpOptions = {
  host: string,
  port: int,
  secure: bool,
  auth: auth,
  connectionTimeout: int,
  greetingTimeout: int,
  socketTimeout: int,
}

// nodemailer's StreamTransport, used only by EmailTest.res: `buffer: true`
// makes it resolve with the whole message as a Buffer instead of a stream.
type streamOptions = {streamTransport: bool, buffer: bool}

type transporter

@module("nodemailer") external createTransport: smtpOptions => transporter = "createTransport"
@module("nodemailer")
external createStreamTransport: streamOptions => transporter = "createTransport"

type envelope = {from: string, to: array<string>}
type mailOptions = {envelope: envelope, raw: string}

@send external sendMail: (transporter, mailOptions) => promise<JSON.t> = "sendMail"

// StreamTransport-only: see the module comment above.
type streamInfo = {envelope: envelope, message: Node.Buffer.t}
@send external sendMailStream: (transporter, mailOptions) => promise<streamInfo> = "sendMail"

// Resolves to `true` on a successful login, rejects otherwise (verified
// against node_modules/nodemailer/dist/cjs/smtp-transport/index.js's
// `verify`, which calls back `(null, true)`).
@send external verify: transporter => promise<bool> = "verify"
