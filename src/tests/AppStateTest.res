// AppState.update: each msg against the expected model. Both pickers, a
// reply, an error, and a second photo clearing the previous one.

let sampleReply: Types.sceneReply = {
  Types.sceneId: "test-scene",
  model: "claude-sonnet-5",
  fixture: true,
  outputPath: "/tmp/test.json",
  items: [],
  timing: {Types.serverMs: 1.0, claudeMs: 2.0, ebayMs: 3.0},
  cost: {
    Types.usd: 0.01,
    inputTokens: 10,
    outputTokens: 5,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    webSearches: 0,
  },
  ebayNote: None,
}

let run = () => {
  TestKit.section("AppState.update")

  let m0 = AppState.initialModel
  TestKit.check("initial model defaults to Sonnet 5", m0.selectedModel == Shared.Sonnet5)
  TestKit.check("initial model defaults to 1568 long edge", m0.longEdge == 1568)

  // -- both pickers ----------------------------------------------------
  let m1 = AppState.update(m0, AppState.SetModel(Shared.Opus5_5))
  TestKit.check("SetModel picks Opus 5.5", m1.selectedModel == Shared.Opus5_5)

  let m2 = AppState.update(m0, AppState.SetLongEdge(2576))
  TestKit.check("SetLongEdge picks 2576", m2.longEdge == 2576)

  // -- a reply -----------------------------------------------------------
  let m3 = AppState.update(m0, AppState.UploadOk(sampleReply, 456.0))
  TestKit.check("a reply sets status to Waiting", m3.status == AppState.Waiting)
  TestKit.check("a reply is stored on the model", m3.reply == Some(sampleReply))
  TestKit.check("a reply records the round trip", m3.rttMs == Some(456.0))

  // -- an error ------------------------------------------------------------
  let m4 = AppState.update(m0, AppState.UploadErr("could not reach the server"))
  TestKit.check(
    "an error sets the status line",
    m4.status == AppState.ErrorStatus("could not reach the server"),
  )
  let m4b = AppState.update(m0, AppState.ResizeErr("could not read that photo"))
  TestKit.check(
    "a resize error also sets the status line",
    m4b.status == AppState.ErrorStatus("could not read that photo"),
  )

  // -- a second photo clears the previous reply and timings ---------------
  let withReply = {...m3, uploadBytes: Some(12345), resizeMs: Some(78.0)}
  let m5 = AppState.update(withReply, AppState.StartPhoto)
  TestKit.check("a second photo resets status to Resizing", m5.status == AppState.Resizing)
  TestKit.check("a second photo clears the old reply", m5.reply == None)
  TestKit.check("a second photo clears the old upload size", m5.uploadBytes == None)
  TestKit.check("a second photo clears the old resize time", m5.resizeMs == None)
  TestKit.check("a second photo clears the old round trip", m5.rttMs == None)
  TestKit.check(
    "a second photo keeps the chosen model",
    m5.selectedModel == withReply.selectedModel,
  )
}
