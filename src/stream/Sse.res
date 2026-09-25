// Incremental parser for the WHATWG "event stream interpretation"
// algorithm (server-sent events). Pure: feed() takes the next chunk of
// text and returns the updated parser state plus any events that chunk
// completed. A line ends in \n, \r\n or \r. A chunk boundary can fall
// anywhere, including between \r and \n, so a lone trailing \r is held
// back until the next feed() call can tell whether \n follows it.

type event = {event: string, data: string}

type t = {
  leftover: string,
  eventType: string,
  dataBuf: string,
}

let empty: t = {leftover: "", eventType: "", dataBuf: ""}

// Process one already-terminated line (no line-ending characters in
// `line`). Mutates the in-progress buffers and appends a completed event
// to `events` on a blank line, per the spec's "dispatch" step.
let processLine = (
  line: string,
  eventType: ref<string>,
  dataBuf: ref<string>,
  events: array<event>,
): unit =>
  if line == "" {
    if dataBuf.contents == "" {
      eventType := ""
    } else {
      let buf = dataBuf.contents
      let data = String.endsWith(buf, "\n")
        ? String.substring(buf, ~start=0, ~end=String.length(buf) - 1)
        : buf
      let name = eventType.contents == "" ? "message" : eventType.contents
      Array.push(events, {event: name, data})->ignore
      dataBuf := ""
      eventType := ""
    }
  } else if String.startsWith(line, ":") {
    ()
  } else {
    let idx = String.indexOf(line, ":")
    let (field, rawValue) = if idx == -1 {
      (line, "")
    } else {
      (
        String.substring(line, ~start=0, ~end=idx),
        String.substring(line, ~start=idx + 1, ~end=String.length(line)),
      )
    }
    let value = String.startsWith(rawValue, " ")
      ? String.substring(rawValue, ~start=1, ~end=String.length(rawValue))
      : rawValue
    switch field {
    | "event" => eventType := value
    | "data" => dataBuf := dataBuf.contents ++ value ++ "\n"
    | _ => ()
    }
  }

let feed = (state: t, chunk: string): (t, array<event>) => {
  let s = state.leftover ++ chunk
  let len = String.length(s)
  let events: array<event> = []
  let eventType = ref(state.eventType)
  let dataBuf = ref(state.dataBuf)
  let rec scan = (pos: int, lineStart: int): string =>
    if pos >= len {
      String.substring(s, ~start=lineStart, ~end=len)
    } else {
      let c = String.charAt(s, pos)
      if c == "\n" {
        processLine(String.substring(s, ~start=lineStart, ~end=pos), eventType, dataBuf, events)
        scan(pos + 1, pos + 1)
      } else if c == "\r" {
        if pos + 1 < len {
          let advance = String.charAt(s, pos + 1) == "\n" ? 2 : 1
          processLine(String.substring(s, ~start=lineStart, ~end=pos), eventType, dataBuf, events)
          scan(pos + advance, pos + advance)
        } else {
          // Ambiguous trailing \r: hold the whole unterminated line back
          // so the next feed() can see whether \n completes it.
          String.substring(s, ~start=lineStart, ~end=len)
        }
      } else {
        scan(pos + 1, lineStart)
      }
    }
  let leftover = scan(0, 0)
  ({leftover, eventType: eventType.contents, dataBuf: dataBuf.contents}, events)
}

let encode = (~event: string, ~data: JSON.t): string =>
  "event: " ++ event ++ "\ndata: " ++ JSON.stringify(data) ++ "\n\n"

let comment = (text: string): string => ": " ++ text ++ "\n\n"
