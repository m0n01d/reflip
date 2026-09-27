// Sse: line-ending variants (\n, \r\n, lone \r, and a \r held back at a
// chunk boundary), comments, multi-line data, the default event name,
// and chunk-boundary independence (a sample split at every index).

let checkEvents = (label: string, events: array<Sse.event>, expected: array<(string, string)>) => {
  TestKit.check(label ++ " count", Array.length(events) == Array.length(expected))
  for i in 0 to Array.length(expected) - 1 {
    switch (Array.get(events, i), Array.get(expected, i)) {
    | (Some(evt), Some((event, data))) =>
        TestKit.check(label ++ " event name matches", evt.event == event)
        TestKit.check(label ++ " data matches", evt.data == data)
    | _ => TestKit.check(label ++ " has enough events", false)
    }
  }
}

let run = () => {
  TestKit.section("Sse")

  // A chunk boundary can fall anywhere without changing the result.
  let sample = "event: foo\ndata: one\n\nevent: bar\ndata: two\n\n"
  let len = String.length(sample)
  let allOk = ref(true)
  for i in 0 to len {
    let (mid, evts1) = Sse.feed(Sse.empty, String.substring(sample, ~start=0, ~end=i))
    let (_, evts2) = Sse.feed(mid, String.substring(sample, ~start=i, ~end=len))
    let combined = Array.concat(evts1, evts2)
    switch (Array.get(combined, 0), Array.get(combined, 1)) {
    | (Some(a), Some(b)) if Array.length(combined) == 2 =>
        if a.event != "foo" || a.data != "one" || b.event != "bar" || b.data != "two" {
          allOk := false
        }
    | _ => allOk := false
    }
  }
  TestKit.check("split at every index reconstructs both events", allOk.contents)

  // CRLF line endings.
  let (_, crlfEvents) = Sse.feed(Sse.empty, "event: foo\r\ndata: one\r\n\r\n")
  checkEvents("CRLF", crlfEvents, [("foo", "one")])

  // Lone CR line endings (old Mac style). The very last \r of a feed()
  // call is itself ambiguous (it could start a \r\n on the next chunk),
  // so it is deferred rather than guessed; one more byte resolves it.
  let (crMid, crEvents1) = Sse.feed(Sse.empty, "event: foo\rdata: one\r\r")
  TestKit.check("lone CR: trailing \\r deferred, nothing dispatched yet", Array.length(crEvents1) == 0)
  let (_, crEvents2) = Sse.feed(crMid, "x")
  checkEvents("lone CR", crEvents2, [("foo", "one")])

  // A CR right at a chunk boundary defers the \n-or-not decision to the
  // next feed() call instead of guessing.
  let (mid, splitEvents1) = Sse.feed(Sse.empty, "event: foo\r")
  TestKit.check("CR held back, no event yet", Array.length(splitEvents1) == 0)
  let (_, splitEvents2) = Sse.feed(mid, "\ndata: one\n\n")
  checkEvents("CR split across chunks", splitEvents2, [("foo", "one")])

  // A comment line is ignored, but does not swallow the event after it.
  let (_, commentEvents) = Sse.feed(Sse.empty, ": keepalive\nevent: foo\ndata: one\n\n")
  checkEvents("comment line ignored", commentEvents, [("foo", "one")])

  // A pure comment (heartbeat) dispatches nothing.
  let (_, heartbeatEvents) = Sse.feed(Sse.empty, ": just a comment\n\n")
  TestKit.check("heartbeat alone dispatches nothing", Array.length(heartbeatEvents) == 0)

  // Multiple data: lines join with \n.
  let (_, multiEvents) = Sse.feed(Sse.empty, "data: line1\ndata: line2\n\n")
  checkEvents("multi-line data", multiEvents, [("message", "line1\nline2")])

  // No event: line means the default event name "message".
  let (_, defaultEvents) = Sse.feed(Sse.empty, "data: solo\n\n")
  checkEvents("default event name", defaultEvents, [("message", "solo")])

  // No data means no dispatch, even once the blank line arrives.
  let (_, noDataEvents) = Sse.feed(Sse.empty, "event: foo\n\n")
  TestKit.check("no data means no dispatch", Array.length(noDataEvents) == 0)

  // encode() and comment() round-trip through feed().
  let payload = Json.obj([("a", Json.num(1.0))])
  let encoded = Sse.encode(~event="widget", ~data=payload)
  let (_, encodedEvents) = Sse.feed(Sse.empty, encoded)
  switch Array.get(encodedEvents, 0) {
  | Some(evt) =>
      TestKit.check("encode event name", evt.event == "widget")
      TestKit.check("encode data", evt.data == JSON.stringify(payload))
  | None => TestKit.check("encode produced an event", false)
  }
  let (_, commentHelperEvents) = Sse.feed(Sse.empty, Sse.comment("hi"))
  TestKit.check("comment() dispatches nothing", Array.length(commentHelperEvents) == 0)
}
