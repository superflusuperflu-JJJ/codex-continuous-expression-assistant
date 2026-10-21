import Foundation
import CoreGraphics
import PrototypeCore

func delayedTranscriptUsesSpeechTime() {
    let anchors = [Anchor(["M1"], start: 1, end: 4), Anchor(["M2"], start: 4)]
    let speech = SpokenSegment(text: "这个间距改大", start: 2, end: 3, words: [TimedWord("这个", start: 2, end: 2.3)])
    expect(Association.bindings(for: speech, anchors: anchors).first?.materialIDs == ["M1"])
    expect(Association.bindings(for: speech, anchors: anchors).first?.certain == true)
}

func twoReferencesInSameSentenceUseWordTimes() {
    let speech = SpokenSegment(text: "这个改间距，这个改颜色", start: 1, end: 7,
        words: [TimedWord("这个", start: 2, end: 2.2), TimedWord("改间距，", start: 2.2, end: 3),
                TimedWord("这个", start: 5, end: 5.2), TimedWord("改颜色", start: 5.2, end: 6)])
    let bindings = Association.bindings(for: speech, anchors: [Anchor(["A"], start: 1, end: 4), Anchor(["B"], start: 4)])
    expect(bindings.map(\.materialIDs) == [["A"], ["B"]])
    expect(bindings.allSatisfy { $0.certain })
}

func missingWordTimingDoesNotGuessAcrossSelectionChange() {
    let speech = SpokenSegment(text: "这个间距这个颜色", start: 1, end: 7)
    let bindings = Association.bindings(for: speech, anchors: [Anchor(["A"], start: 1, end: 4), Anchor(["B"], start: 4)])
    expect(bindings.count == 2)
    expect(bindings.allSatisfy { !$0.certain })
}

func negationAndHistoryAreNotBoundToCurrentSelection() {
    for text in ["不是这个，是上一个", "参考刚才那个"] {
        let result = Association.bindings(for: SpokenSegment(text: text, start: 2, end: 3), anchors: [Anchor(["A"], start: 1)])
        expect(!result.isEmpty)
        expect(result.allSatisfy { !$0.certain })
    }
}

func uncertaintyAroundBoundaryDoesNotProduceCertainty() {
    let result = Association.bindings(for: SpokenSegment(text: "这个", start: 4, end: 4.1),
        anchors: [Anchor(["A"], start: 1, end: 4, uncertainty: 0.2), Anchor(["B"], start: 4, uncertainty: 0.2)])
    expect(result.first?.certain == false)
}

func fileSetRemainsASet() {
    let result = Association.bindings(for: SpokenSegment(text: "这两个文件", start: 2, end: 3), anchors: [Anchor(["A", "B"], start: 1)])
    expect(result.first?.materialIDs == ["A", "B"])
}

func renderKeepsOriginalCorrectionsAndGaps() {
    let output = PromptRenderer.render(materials: [Material(id: "A", kind: "file", label: "参考.pdf", source: "Finder", content: "/test.pdf")],
        segments: [SpokenSegment(text: "不，刚才那条取消", start: 2, end: 3)], anchors: [], gaps: ["语音尚未结束识别"])
    expect(output.contains("不，刚才那条取消"))
    expect(output.contains("语音尚未结束识别"))
    expect(output.contains("参考.pdf"))
}

func inFlightWorkPreventsPrematureFinalization() {
    var barrier = WorkBarrier()
    let token = barrier.begin(at: 2)
    expect(!barrier.ready(through: 3))
    barrier.settle(token)
    expect(barrier.ready(through: 3))
    _ = barrier.begin(at: 5)
    expect(barrier.ready(through: 3))
}

var failures = 0
func expect(_ condition: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !condition() { failures += 1; print("FAIL: \(file):\(line)") }
}
@main struct Checks {
    static func main() {
        delayedTranscriptUsesSpeechTime()
        twoReferencesInSameSentenceUseWordTimes()
        missingWordTimingDoesNotGuessAcrossSelectionChange()
        negationAndHistoryAreNotBoundToCurrentSelection()
        uncertaintyAroundBoundaryDoesNotProduceCertainty()
        fileSetRemainsASet()
        renderKeepsOriginalCorrectionsAndGaps()
        inFlightWorkPreventsPrematureFinalization()
        preCutoffArrivalsRemainAcceptable()
        outOfOrderArrivalsDoNotMakeOlderSelectionCurrent()
        silencePaddingDoesNotCountAsCutoffSpeech()
        fastFinderSelectionCanBindAfterObservedRead()
        finderBoundaryStillRefusesPrematureSpeech()
        differentBoundaryErrorsDoNotInventCertainty()
        recordingFileTimesPreserveHostGaps()
        finalDecoderFragmentsBecomeReadableUtterances()
        punctuationPaddingDoesNotInventLateSpeech()
        compositionHidesUnspokenDragFragments()
        compositionKeepsSpokenIntermediateSelection()
        semanticResultCanMergeThreeUtterances()
        semanticValidationRejectsUnknownOrMissingSources()
        semanticCancellationNeedsLaterReplacement()
        uncertainReferencesStayUnresolved()
        compositionDoesNotSendFileContentsOrInlineImages()
        certainTargetsCannotDisappear()
        paragraphReferencesUseTheirOwnWordTimes()
        continuousDragResolvesToCompletedName()
        continuousDragDoesNotEraseEarlierIndependentTarget()
        completedGestureUsesFinalRangeWhileSpeaking()
        separateGesturesAreNotMergedBySimilarNames()
        stableIndependentSelectionsAreNotDragFragments()
        recommendedResolutionAppearsInPrompt()
        choiceUpdatesPreserveManualChanges()
        choiceRejectsAmbiguousDuplicateBlocks()
        recommendationsRespectIndividualAnswers()
        resolutionRejectsUnrelatedMaterials()
        duplicateManagedParagraphsAreRejected()
        recommendationsRespectTaskOrder()
        unselectedAlternativeCannotPreserveCertainTarget()
        unresolvedPromptRetainsFullTask()
        choosingDuplicateTextDoesNotBreakOtherChoice()
        multilineCustomAnswerCanBeChangedAgain()
        deletedManagedBlockCannotBindToManualCopy()
        punctuationOnlyTranscriptCanBeDiscardedWithoutLosingTask()
        desktopTargetRequiresExactLiveIdentity()
        accessibilityDiagnosticRedactsProseAndRejectsPartialEvidence()
        syntheticDraftRejectsWrongWindowAndExistingText()
        draftReadbackWaitsForAsyncEchoWithoutRelaxingIdentity()
        reviewedDraftRequiresHumanTargetCheck()
        boundDraftRequiresExactLiveConversationID()
        copyLinkFailureStillRestoresItsOwnClipboardResult()
        drawerWaitsAtEdgeAndCancelsAccidentalPass()
        drawerLeavingCanBeCancelledAndBlocked()
        drawerGeometryFitsNegativeOriginAndSmallScreens()
        drawerSpringSettlesAndRetargetsContinuously()
        drawerReduceMotionIsImmediateAndBounded()
        drawerExplicitHideResetsPendingHover()
        hiddenDrawerCanRecoverWithAttachedDialog()
        drawerSpringDoesNotDependOnTimerCadence()
        drawerReturnsDuringClosingWithoutEdgeDwell()
        drawerOnlyCurrentCompletionReenablesPointer()
        drawerReduceMotionDoesNotBlockPointer()
        desktopSendCanOnlyConsumeVerifiedAttemptOnce()
        desktopSendRejectsChangedTargetTextOrFocus()
        desktopSendRejectsAmbiguousDisabledOrBusyControls()
        desktopSendAcceptsOnlyExplicitSendButtonLabels()
        desktopSendInvokesActualActionOnce()
        desktopSendDoesNotInvokeActionAfterTargetChanges()
        desktopComposerReusesOnlyExactApprovedDraft()
        desktopComposerProtectsDifferentDrafts()
        desktopSubmitShortcutRequiresPlainOpening()
        draftFocusRequestsOnceAndRequiresStableReadback()
        draftFocusRejectsWindowOrDraftChanges()
        print("73 checks; \(failures) failed assertions")
        exit(failures == 0 ? 0 : 1)
    }
}

func preCutoffArrivalsRemainAcceptable() {
    expect(CaptureOrdering.accepts(time:2,cutoff:3,collecting:false,finalizing:true))
    expect(!CaptureOrdering.accepts(time:4,cutoff:3,collecting:false,finalizing:true))
    expect(!CaptureOrdering.accepts(time:2,cutoff:3,collecting:false,finalizing:false))
}
func outOfOrderArrivalsDoNotMakeOlderSelectionCurrent() {
    let anchors = CaptureOrdering.sortedIntervals([Anchor(["B"],start:5),Anchor(["A"],start:2)])
    let refs = Association.bindings(for:SpokenSegment(text:"这个",start:6,end:7),anchors:anchors)
    expect(refs.first?.materialIDs == ["B"])
    expect(refs.first?.certain == true)
}

func silencePaddingDoesNotCountAsCutoffSpeech() {
    let padded = SpokenSegment(text: "原文件", start: 1, end: 2.4,
        words: [TimedWord("原文件", start: 1.2, end: 1.9)])
    expect(!padded.hasSpeech(after: 2.1))
    expect(padded.hasSpeech(after: 1.8))
    expect(SpokenSegment(text: "无词级计时", start: 1, end: 2.4).hasSpeech(after: 2.1))
}

func fastFinderSelectionCanBindAfterObservedRead() {
    var tracker = SelectionObservationWindow()
    _ = tracker.observe(start: 1, end: 1.015)
    let change = tracker.observe(start: 1.06, end: 1.075)
    let a = Anchor(["A", "B"], start: change.time, uncertainty: change.uncertainty)
    let speech = SpokenSegment(text: "这两个", start: 1.10, end: 1.4)
    expect(Association.bindings(for: speech, anchors: [a]).first?.certain == true)
}
func finderBoundaryStillRefusesPrematureSpeech() {
    var tracker = SelectionObservationWindow()
    _ = tracker.observe(start: 1, end: 1.015)
    let change = tracker.observe(start: 1.06, end: 1.075)
    let a = Anchor(["A", "B"], start: change.time, uncertainty: change.uncertainty)
    expect(Association.bindings(for: SpokenSegment(text: "这两个", start: 1.03, end: 1.05), anchors: [a]).first?.certain == false)
}
func differentBoundaryErrorsDoNotInventCertainty() {
    let a = CaptureOrdering.sortedIntervals([Anchor(["A"], start: 1, uncertainty: 0.01), Anchor(["B"], start: 2, uncertainty: 0.2)])
    expect(Association.bindings(for: SpokenSegment(text: "这个", start: 1.85, end: 1.9), anchors: a).allSatisfy { !$0.certain })
}
func recordingFileTimesPreserveHostGaps() {
    let spans = [AudioSpan(audioStart: 0, audioEnd: 1, hostStart: 100), AudioSpan(audioStart: 1, audioEnd: 2, hostStart: 102)]
    expect(abs(RecordingTimeline.hostTime(0.5, spans: spans, fallbackOrigin: 0) - 100.5) < 0.00001)
    expect(abs(RecordingTimeline.hostTime(1.5, spans: spans, fallbackOrigin: 0) - 102.5) < 0.00001)
    expect(abs(RecordingTimeline.hostTime(1, spans: spans, fallbackOrigin: 0) - 102) < 0.00001)
    expect(abs(RecordingTimeline.hostTime(1, spans: spans, fallbackOrigin: 0, endBoundary: true) - 101) < 0.00001)
    expect(abs(RecordingTimeline.hostTime(1 + 1e-12, spans: spans, fallbackOrigin: 0, endBoundary: true) - 101) < 0.00001)
}

func finalDecoderFragmentsBecomeReadableUtterances() {
    let parts = [SpokenSegment(id:"a",text:"这两个文件不要",start:1,end:2,
            words:[TimedWord("这两个文件不要",start:1,end:2)]),
        SpokenSegment(id:"b",text:"修改",start:2,end:2.4,words:[TimedWord("修改",start:2,end:2.4)]),
        SpokenSegment(id:"c",text:"原文件。",start:2.4,end:3,words:[TimedWord("原文件。",start:2.4,end:3)])]
    let joined = TranscriptAssembly.coalesced(parts)
    expect(joined.count == 1)
    expect(joined.first?.text == "这两个文件不要修改原文件。")
    expect(joined.first?.words.count == 3 && joined.first?.words.last?.start == 2.4)
    let repetition = TranscriptAssembly.coalesced([SpokenSegment(text:"一点",start:1,end:2),SpokenSegment(text:"一点",start:2,end:3)])
    expect(repetition.map(\.text).joined() == "一点一点")
    expect(TranscriptAssembly.coalesced([parts[0],SpokenSegment(text:"另一条要求",start:5,end:6)]).count == 2)
}
func punctuationPaddingDoesNotInventLateSpeech() {
    let speech = SpokenSegment(text:"改短。",start:1,end:3,words:[TimedWord("改短",start:1,end:2),TimedWord("。",start:2,end:3)])
    expect(!speech.hasSpeech(after:2.2))
}

func compositionFixture() -> PromptContext {
    let materials = [Material(id:"M1",kind:"文字",label:"按钮说",source:"web",content:"按钮说"),
        Material(id:"M2",kind:"文字",label:"按钮说明",source:"web",content:"按钮说明"),
        Material(id:"M3",kind:"图片",label:"布局图片",source:"web",content:"data:image/png;base64,PRIVATE_PIXELS",localPath:"/private/image.jpg",availability:"excerpt"),
        Material(id:"M4",kind:"文件",label:"参考A.txt",source:"Finder",content:"/private/secret/参考A.txt",localPath:"/private/copy.txt")]
    let anchors = [Anchor(["M1"],start:0,end:0.1,source:"web"),Anchor(["M2"],start:0.1,end:3,source:"web"),
                   Anchor(["M3"],start:3,end:5,source:"web"),Anchor(["M4"],start:5,end:9,source:"Finder")]
    let speech = [SpokenSegment(id:"s1",text:"这个改短一点",start:1,end:2),
        SpokenSegment(id:"s2",text:"这个图片参考布局",start:3.5,end:4.5),
        SpokenSegment(id:"s3",text:"这份文件作为参考，不要修改原文件",start:6,end:7)]
    return PromptComposition.context(materials:materials,segments:speech,anchors:anchors,gaps:[])
}
func compositionHidesUnspokenDragFragments() {
    let context = compositionFixture()
    expect(context.materials.map(\.id) == ["M2","M3","M4"])
    expect(context.speech.map(\.id) == ["s1","s2","s3"])
}
func compositionKeepsSpokenIntermediateSelection() {
    let a = Material(id:"A",kind:"文字",label:"短词",source:"web",content:"短词")
    let b = Material(id:"B",kind:"文字",label:"短词扩展",source:"web",content:"短词扩展")
    let context = PromptComposition.context(materials:[a,b],segments:[SpokenSegment(id:"s",text:"这个",start:0.03,end:0.05)],
        anchors:[Anchor(["A"],start:0,end:0.1,source:"web"),Anchor(["B"],start:0.1,end:3,source:"web")],gaps:[])
    expect(context.materials.map(\.id).contains("A"))
}
func validComposition() -> OrganizedPrompt {
    OrganizedPrompt(paragraphs:[PromptParagraph(text:"请把选中文字[M2]改得更简短，布局参考图片[M3]。文件[M4]仅作参考，不要修改原文件。",speechIDs:["s1","s2","s3"],materialIDs:["M2","M3","M4"])],
        decisions:[SpeechDecision("s1","included"),SpeechDecision("s2","included"),SpeechDecision("s3","included")])
}
func semanticResultCanMergeThreeUtterances() {
    let context = compositionFixture(), result = validComposition()
    expect((try? PromptComposition.validate(result,for:context)) != nil)
    let output = PromptComposition.render(result,context:context)
    expect(output.hasPrefix("请把选中文字"))
    expect(output.contains("不要修改原文件"))
    expect(!output.contains("用户表达（按发生顺序）"))
    expect(!output.contains("[M1]"))
}
func semanticValidationRejectsUnknownOrMissingSources() {
    let context = compositionFixture()
    var wrong = validComposition(); wrong.paragraphs[0].materialIDs = ["M999"]
    expect((try? PromptComposition.validate(wrong,for:context)) == nil)
    wrong = validComposition(); wrong.decisions.removeLast()
    expect((try? PromptComposition.validate(wrong,for:context)) == nil)
}
func semanticCancellationNeedsLaterReplacement() {
    let context = PromptContext(speech:[PromptSpeech(id:"s1",text:"改成红色",bindings:[]),PromptSpeech(id:"s2",text:"取消颜色修改，只调整间距",bindings:[])],materials:[],gaps:[])
    var result = OrganizedPrompt(paragraphs:[PromptParagraph(text:"仅调整间距，保留原有颜色。",speechIDs:["s2"],materialIDs:[])],decisions:[SpeechDecision("s1","superseded",replacements:["s2"],reason:"用户随后撤回"),SpeechDecision("s2","included")])
    expect((try? PromptComposition.validate(result,for:context)) != nil)
    expect(!PromptComposition.render(result,context:context).contains("改成红色"))
    result.decisions[0].replacementSpeechIDs = []
    expect((try? PromptComposition.validate(result,for:context)) == nil)
}
func uncertainReferencesStayUnresolved() {
    let context = PromptContext(speech:[PromptSpeech(id:"s",text:"用上一个",bindings:[Binding(phrase:"上一个",materialIDs:["M2"],certain:false,explanation:"历史指代")])],materials:compositionFixture().materials,gaps:[])
    let guessed = OrganizedPrompt(paragraphs:[PromptParagraph(text:"使用[M2]",speechIDs:["s"],materialIDs:["M2"])],decisions:[SpeechDecision("s","included")])
    expect((try? PromptComposition.validate(guessed,for:context)) == nil)
}
func compositionDoesNotSendFileContentsOrInlineImages() {
    let context = compositionFixture()
    let encoded = String(data:try! JSONEncoder().encode(context),encoding:.utf8)!
    expect(!encoded.contains("PRIVATE_PIXELS"))
    expect(!encoded.contains("/private/"))
    expect(encoded.contains("参考A.txt"))
}

func certainTargetsCannotDisappear() {
    let context = compositionFixture()
    var result = validComposition()
    result.paragraphs[0].text = "请改短文字，参考图片布局，不要修改原文件。"
    result.paragraphs[0].materialIDs = []
    expect((try? PromptComposition.validate(result,for:context)) == nil)
}

func paragraphReferencesUseTheirOwnWordTimes() {
    let speech = SpokenSegment(text:"这一段精简，再把这段作为参考",start:1,end:8,
        words:[TimedWord("这一段",start:2,end:2.4),TimedWord("精简，再把",start:2.4,end:4),TimedWord("这段",start:6,end:6.4),TimedWord("作为参考",start:6.4,end:8)])
    let bindings = Association.bindings(for:speech,anchors:[Anchor(["A"],start:1,end:4),Anchor(["B"],start:5,end:9)])
    expect(bindings.map(\.phrase) == ["这一段","这段"])
    expect(bindings.map(\.materialIDs) == [["A"],["B"]])
    expect(bindings.allSatisfy(\.certain))
}

func continuousDragResolvesToCompletedName() {
    let items = [Material(id:"M1",kind:"文字",label:"C",source:"web",content:"C"),
        Material(id:"M2",kind:"文字",label:"Cla",source:"web",content:"Cla"),
        Material(id:"M3",kind:"文字",label:"Clash",source:"web",content:"Clash"),
        Material(id:"M4",kind:"文字",label:"Clash Verge",source:"web",content:"Clash Verge")]
    let points = [Anchor(["M1"],start:10,end:10.1,source:"web",uncertainty:0.06),
        Anchor(["M2"],start:10.1,end:10.2,source:"web",uncertainty:0.05),
        Anchor(["M3"],start:10.2,end:10.7,source:"web",uncertainty:0.05),
        Anchor(["M4"],start:10.7,end:15,source:"web",uncertainty:0.04)]
    let speech = SpokenSegment(id:"request",text:"把这个软件的官网找出来",start:9.5,end:14,
        words:[TimedWord("把",start:9.5,end:10.05),TimedWord("这个",start:10.05,end:10.92),TimedWord("软件的官网找出来",start:10.92,end:14)])
    let context = PromptComposition.context(materials:items,segments:[speech],anchors:points,gaps:[])
    expect(context.speech.first?.bindings.first?.materialIDs == ["M4"])
    expect(context.speech.first?.bindings.first?.certain == true)
    expect(context.materials.map(\.id) == ["M4"])
    expect(PromptComposition.localDraft(context).contains("文字[M4]软件的官网"))
}
func continuousDragDoesNotEraseEarlierIndependentTarget() {
    let items = [Material(id:"M1",kind:"文字",label:"Clash",source:"web",content:"Clash"),
        Material(id:"M2",kind:"文字",label:"C",source:"web",content:"C"),
        Material(id:"M3",kind:"文字",label:"Cla",source:"web",content:"Cla"),
        Material(id:"M4",kind:"文字",label:"Clash Verge",source:"web",content:"Clash Verge")]
    let points = [Anchor(["M1"],start:1,end:5,source:"web"),Anchor(["M2"],start:10,end:10.1,source:"web"),
        Anchor(["M3"],start:10.1,end:10.2,source:"web"),Anchor(["M4"],start:10.2,end:15,source:"web")]
    let context = PromptComposition.context(materials:items,segments:[SpokenSegment(id:"old",text:"这个保留",start:2,end:3),SpokenSegment(id:"new",text:"这个找官网",start:10.05,end:10.4)],anchors:points,gaps:[])
    expect(context.speech.map { $0.bindings.first?.materialIDs ?? [] } == [["M1"],["M4"]])
    expect(context.materials.map(\.id).contains("M1"))
}

func completedGestureUsesFinalRangeWhileSpeaking() {
    let items = [Material(id:"A",kind:"文字",label:"Clash Verge",source:"web",content:"Clash Verge"),Material(id:"B",kind:"文字",label:"Verge",source:"web",content:"Verge")]
    let points = [Anchor(["A"],start:10.8,end:11,source:"web",selectionID:"drag",selectionComplete:false,selectionStart:10),
        Anchor(["B"],start:11,end:15,source:"web",selectionID:"drag",selectionComplete:true,selectionStart:10)]
    let context = PromptComposition.context(materials:items,segments:[SpokenSegment(id:"s",text:"这个改短",start:10.2,end:10.7)],anchors:points,gaps:[])
    expect(context.speech.first?.bindings.first?.materialIDs == ["B"])
    expect(context.speech.first?.bindings.first?.certain == true)
}
func separateGesturesAreNotMergedBySimilarNames() {
    let items = [Material(id:"A",kind:"文字",label:"C",source:"web",content:"C"),Material(id:"B",kind:"文字",label:"Cla",source:"web",content:"Cla"),Material(id:"C",kind:"文字",label:"Clash Verge",source:"web",content:"Clash Verge")]
    let points = [Anchor(["A"],start:1,end:1.1,source:"web",selectionID:"one",selectionComplete:true),
        Anchor(["B"],start:1.1,end:1.2,source:"web",selectionID:"two",selectionComplete:true),
        Anchor(["C"],start:1.2,end:4,source:"web",selectionID:"three",selectionComplete:true)]
    let context = PromptComposition.context(materials:items,segments:[SpokenSegment(id:"s",text:"这个",start:1.05,end:1.4)],anchors:points,gaps:[])
    expect(context.speech.first?.bindings.first?.certain == false)
    expect(Set(context.speech.first?.bindings.first?.materialIDs ?? []) == Set(["A","B","C"]))
}
func stableIndependentSelectionsAreNotDragFragments() {
    let items = [Material(id:"A",kind:"文字",label:"C",source:"web",content:"C"),Material(id:"B",kind:"文字",label:"Cla",source:"web",content:"Cla"),Material(id:"C",kind:"文字",label:"Clash Verge",source:"web",content:"Clash Verge")]
    let points = [Anchor(["A"],start:1,end:4,source:"web"),Anchor(["B"],start:4,end:7,source:"web"),Anchor(["C"],start:7,end:10,source:"web")]
    let context = PromptComposition.context(materials:items,segments:[SpokenSegment(id:"s",text:"这个",start:2,end:3)],anchors:points,gaps:[])
    expect(context.speech.first?.bindings.first?.materialIDs == ["A"])
    expect(context.speech.first?.bindings.first?.certain == true)
}

func recommendedResolutionAppearsInPrompt() {
    let data = Data(#"{"paragraphs":[],"unresolved":[],"decisions":[{"speechID":"s","disposition":"included","replacementSpeechIDs":[],"reason":"选区明确给出名称"}],"resolutions":[{"id":"software","question":"查找哪个软件的官网？","reason":"口述查找软件官网且选区为完整软件名","speechIDs":["s"],"options":[{"label":"Clash Verge","text":"查找 Clash Verge [M1] 的官网。","materialIDs":["M1"]}],"applyByDefault":true}]}"#.utf8)
    let result = try! JSONDecoder().decode(OrganizedPrompt.self,from:data)
    let context = PromptContext(speech:[PromptSpeech(id:"s",text:"找这个软件官网",bindings:[Binding(phrase:"这个",materialIDs:["M1"],certain:false,explanation:"时间边界不精确")])],materials:PromptComposition.context(materials:[Material(id:"M1",kind:"文字",label:"软件",source:"web",content:"Clash Verge")],segments:[],anchors:[],gaps:[]).materials,gaps:[])
    expect(PromptComposition.render(result,context:context).contains("查找 Clash Verge [M1] 的官网。"))
    expect((try? PromptComposition.validate(result,for:context)) != nil)
}

func choiceFixture() -> ReviewChoice {
    let json = #"{"id":"software","question":"哪个软件？","reason":"选中软件名","speechIDs":["s"],"options":[{"label":"Clash Verge","text":"查找 Clash Verge [M1] 官网。","materialIDs":["M1"]},{"label":"Clash","text":"查找 Clash [M2] 官网。","materialIDs":["M2"]}],"applyByDefault":false}"#
    return ReviewChoice(try! JSONDecoder().decode(PromptResolution.self,from:Data(json.utf8)))
}
func choiceUpdatesPreserveManualChanges() {
    var choice = choiceFixture()
    var prompt = "我手写的开头。\n\n" + choice.appliedBlock + "\n\n请保留这句限制。"
    expect(ReviewChoices.apply(0,choice:&choice,prompt:&prompt))
    expect(prompt == "我手写的开头。\n\n查找 Clash Verge [M1] 官网。\n\n请保留这句限制。")
    prompt = prompt.replacingOccurrences(of:"查找 Clash Verge [M1] 官网。",with:"仅介绍软件，不要查官网。")
    let edited = prompt
    expect(!ReviewChoices.apply(1,choice:&choice,prompt:&prompt))
    expect(prompt == edited && choice.conflict)
    prompt = "我把原要求完全删除了。"
    expect(!ReviewChoices.apply(0,choice:&choice,prompt:&prompt))
    expect(prompt == "我把原要求完全删除了。")
}
func choiceRejectsAmbiguousDuplicateBlocks() {
    var choice = choiceFixture()
    var prompt = choice.appliedBlock + "\n\n" + choice.appliedBlock
    let original = prompt
    expect(!ReviewChoices.apply(0,choice:&choice,prompt:&prompt))
    expect(prompt == original)
}
func recommendationsRespectIndividualAnswers() {
    var choices = [choiceFixture()]
    var prompt = choices[0].appliedBlock
    expect(!ReviewChoices.apply(nil,custom:"  ",choice:&choices[0],prompt:&prompt))
    expect(ReviewChoices.apply(nil,custom:"只介绍软件，不要搜索。",choice:&choices[0],prompt:&prompt))
    expect(ReviewChoices.applyRecommended(choices:&choices,prompt:&prompt) == 0)
    expect(prompt == "只介绍软件，不要搜索。")
    var fresh = [choiceFixture()]
    prompt = fresh[0].appliedBlock
    expect(ReviewChoices.applyRecommended(choices:&fresh,prompt:&prompt) == 1)
    expect(prompt == "查找 Clash Verge [M1] 官网。")
    var withDraft = [choiceFixture()]
    withDraft[0].customText = "我还在写自己的要求"
    var draftPrompt = withDraft[0].appliedBlock
    let unchanged = draftPrompt
    expect(ReviewChoices.applyRecommended(choices:&withDraft,prompt:&draftPrompt) == 0)
    expect(draftPrompt == unchanged && withDraft[0].customText == "我还在写自己的要求")
    let restored = try! JSONDecoder().decode([ReviewChoice].self,from:JSONEncoder().encode(fresh))
    expect(restored[0].userChosen && restored[0].appliedBlock == prompt)
}
func resolutionRejectsUnrelatedMaterials() {
    let choice = choiceFixture()
    let context = PromptComposition.context(materials:[Material(id:"M1",kind:"文字",label:"软件",source:"web",content:"Clash Verge"),Material(id:"M2",kind:"文字",label:"其他",source:"web",content:"Clash")],segments:[SpokenSegment(id:"s",text:"这个找官网",start:1,end:2)],anchors:[Anchor(["M1"],start:0,end:3)],gaps:[])
    let result = OrganizedPrompt(paragraphs:[],decisions:[SpeechDecision("s","included")],resolutions:[choice.resolution])
    expect((try? PromptComposition.validate(result,for:context)) == nil)
}

func duplicateManagedParagraphsAreRejected() {
    let json = #"{"paragraphs":[{"text":"查找 Clash Verge [M1] 官网。","speechIDs":["s"],"materialIDs":["M1"]}],"unresolved":[],"decisions":[{"speechID":"s","disposition":"included","replacementSpeechIDs":[],"reason":"软件明确"}],"resolutions":[{"id":"software","question":"哪个软件？","reason":"选中软件名","speechIDs":["s"],"options":[{"label":"Clash Verge","text":"查找 Clash Verge [M1] 官网。","materialIDs":["M1"]}],"applyByDefault":true}]}"#
    let result = try! JSONDecoder().decode(OrganizedPrompt.self,from:Data(json.utf8))
    let context = PromptComposition.context(materials:[Material(id:"M1",kind:"文字",label:"软件",source:"web",content:"Clash Verge")],segments:[SpokenSegment(id:"s",text:"这个找官网",start:1,end:2)],anchors:[Anchor(["M1"],start:0,end:3)],gaps:[])
    expect((try? PromptComposition.validate(result,for:context)) == nil)
}

func recommendationsRespectTaskOrder() {
    let json = #"{"paragraphs":[{"text":"最后展示邀请码。","speechIDs":["s"],"materialIDs":[]}],"unresolved":[],"decisions":[{"speechID":"s","disposition":"included","replacementSpeechIDs":[],"reason":"保留"}],"resolutions":[{"id":"software","question":"哪个软件？","reason":"选中名称","speechIDs":["s"],"options":[{"label":"Clash Verge","text":"先查找官网。","materialIDs":[]}],"applyByDefault":true,"position":0}]}"#
    let result = try! JSONDecoder().decode(OrganizedPrompt.self,from:Data(json.utf8))
    let output = PromptComposition.render(result,context:PromptContext(speech:[],materials:[],gaps:[]))
    expect(output == "先查找官网。\n\n最后展示邀请码。")
}

func unselectedAlternativeCannotPreserveCertainTarget() {
    var choice = choiceFixture(); choice.resolution.applyByDefault = true
    choice.resolution.options.swapAt(0,1)
    let context = PromptComposition.context(materials:[Material(id:"M1",kind:"文字",label:"软件",source:"web",content:"Clash Verge"),Material(id:"M2",kind:"文字",label:"其他",source:"web",content:"Clash")],segments:[SpokenSegment(id:"s",text:"这个找官网",start:1,end:2)],anchors:[Anchor(["M1"],start:0,end:3)],gaps:[])
    var contextWithAlternative = context
    contextWithAlternative.speech[0].selectedMaterialIDs.append("M2")
    let result = OrganizedPrompt(paragraphs:[],decisions:[SpeechDecision("s","included")],resolutions:[choice.resolution])
    expect((try? PromptComposition.validate(result,for:contextWithAlternative)) == nil)
}
func unresolvedPromptRetainsFullTask() {
    let choice = choiceFixture()
    expect(choice.appliedBlock.contains("查找 Clash Verge [M1] 官网。"))
    expect(choice.appliedBlock.contains("尚未采用"))
}
func choosingDuplicateTextDoesNotBreakOtherChoice() {
    var choice = choiceFixture()
    var prompt = choice.appliedBlock + "\n\n查找 Clash [M2] 官网。"
    let before = prompt
    expect(!ReviewChoices.apply(1,choice:&choice,prompt:&prompt))
    expect(prompt == before)
    expect(ReviewChoices.apply(0,choice:&choice,prompt:&prompt))
}
func multilineCustomAnswerCanBeChangedAgain() {
    var choice = choiceFixture(); var prompt = choice.appliedBlock
    expect(ReviewChoices.apply(nil,custom:"先介绍软件。\n\n不要联网。",choice:&choice,prompt:&prompt))
    expect(ReviewChoices.apply(0,choice:&choice,prompt:&prompt))
    expect(prompt == "查找 Clash Verge [M1] 官网。")
}

func deletedManagedBlockCannotBindToManualCopy() {
    var choices = [choiceFixture()]
    var prompt = choices[0].appliedBlock
    expect(ReviewChoices.applyRecommended(choices:&choices,prompt:&prompt) == 1)
    let copy = prompt + "\n\n" + prompt
    ReviewChoices.markManualEdit(choices:&choices,oldPrompt:prompt,newPrompt:copy)
    ReviewChoices.markManualEdit(choices:&choices,oldPrompt:copy,newPrompt:prompt)
    let before = prompt
    expect(!ReviewChoices.apply(1,choice:&choices[0],prompt:&prompt))
    expect(prompt == before)
}

func punctuationOnlyTranscriptCanBeDiscardedWithoutLosingTask() {
    for noise in ["。", " ，。！ ", "…"] {
        let context = PromptContext(speech:[PromptSpeech(id:"noise",text:noise,bindings:[]),PromptSpeech(id:"task",text:"请精简简介",bindings:[])],materials:[],gaps:[])
        let result = OrganizedPrompt(paragraphs:[PromptParagraph(text:"请精简简介。",speechIDs:["task"],materialIDs:[])],decisions:[SpeechDecision("noise","filler"),SpeechDecision("task","included")])
        expect((try? PromptComposition.validate(result,for:context)) != nil)
    }
    for task in ["删掉。", "不要修改！", "👍"] {
        let context = PromptContext(speech:[PromptSpeech(id:"task",text:task,bindings:[])],materials:[],gaps:[])
        let result = OrganizedPrompt(paragraphs:[],decisions:[SpeechDecision("task","filler")])
        expect((try? PromptComposition.validate(result,for:context)) == nil)
    }
}

func desktopTargetRequiresExactLiveIdentity() {
    let id = "00000000-0000-4000-8000-000000000002"
    expect(DesktopTargetVerification.matches(bundleID:"com.openai.codex",documentURL:"codex://threads/"+id,expectedThreadID:id))
    expect(!DesktopTargetVerification.matches(bundleID:"com.openai.codex",documentURL:nil,expectedThreadID:id))
    expect(!DesktopTargetVerification.matches(bundleID:"com.openai.codex",documentURL:"codex://threads/other",expectedThreadID:id))
    expect(!DesktopTargetVerification.matches(bundleID:"com.apple.Safari",documentURL:"codex://threads/"+id,expectedThreadID:id))
    expect(!DesktopTargetVerification.matches(bundleID:"com.openai.codex",documentURL:"https://example.com/?thread="+id,expectedThreadID:id))
    expect(!DesktopTargetVerification.matches(bundleID:"com.openai.codex",documentURL:"codex://threads/"+id+"/other",expectedThreadID:id))
}

func accessibilityDiagnosticRedactsProseAndRejectsPartialEvidence() {
    let title = "连续表达联通测试"
    let secret = "这是用户私密草稿，请不要记录明文"
    expect(!AXDiagnosticEvidence.safeLabel(secret,targetTitle:title).contains(secret))
    expect(AXDiagnosticEvidence.safeLabel("发送",targetTitle:title) == "发送")
    expect(AXDiagnosticEvidence.safeLabel(title,targetTitle:title) == title)
    let id = "00000000-0000-4000-8000-000000000002", urls = ["codex://threads/00000000-0000-4000-8000-000000000002"]
    expect(AXDiagnosticEvidence.snapshotMatches(urls:urls,webAreaCount:1,complete:true,expectedThreadID:id))
    expect(!AXDiagnosticEvidence.snapshotMatches(urls:urls,webAreaCount:2,complete:true,expectedThreadID:id))
    expect(!AXDiagnosticEvidence.snapshotMatches(urls:urls,webAreaCount:1,complete:false,expectedThreadID:id))
    expect(!AXDiagnosticEvidence.snapshotMatches(urls:[],webAreaCount:1,complete:true,expectedThreadID:id))
}

func syntheticDraftRejectsWrongWindowAndExistingText() {
    let id = "00000000-0000-4000-8000-000000000002"
    let title = "连续表达联通测试 · " + id
    expect(DesktopTargetVerification.allowsSyntheticDraft(bundleID:"com.openai.codex",windowTitle:title,expectedThreadID:id,fieldCount:1,currentValue:"\n"))
    expect(!DesktopTargetVerification.allowsSyntheticDraft(bundleID:"com.openai.codex",windowTitle:"连续表达联通测试",expectedThreadID:id,fieldCount:1,currentValue:""))
    expect(!DesktopTargetVerification.allowsSyntheticDraft(bundleID:"com.openai.codex",windowTitle:title,expectedThreadID:id,fieldCount:2,currentValue:""))
    expect(!DesktopTargetVerification.allowsSyntheticDraft(bundleID:"com.openai.codex",windowTitle:title,expectedThreadID:id,fieldCount:1,currentValue:"用户还没发送的草稿"))
    expect(!DesktopTargetVerification.allowsSyntheticDraft(bundleID:"com.apple.Safari",windowTitle:title,expectedThreadID:id,fieldCount:1,currentValue:""))
}

func draftReadbackWaitsForAsyncEchoWithoutRelaxingIdentity() {
    var check = DraftReadbackVerification(expected:"正文\n保留空格 ")
    expect(check.observe(echo:"\n",identityStable:true) == .waiting)
    expect(check.observe(echo:"正文\n保留空格 ",identityStable:true) == .waiting)
    expect(check.observe(echo:"正文\n保留空格 ",identityStable:true) == .verified)
    var changed = DraftReadbackVerification(expected:"正文")
    expect(changed.observe(echo:"正文",identityStable:false) == .targetChanged)
    expect(changed.observe(echo:"正文",identityStable:true) == .targetChanged)
    var unicode = DraftReadbackVerification(expected:"é")
    expect(unicode.observe(echo:"e\u{301}",identityStable:true) == .waiting)
    expect(unicode.observe(echo:"e\u{301}",identityStable:true) == .waiting)
    var altered = DraftReadbackVerification(expected:"正文 ")
    expect(altered.observe(echo:"正文",identityStable:true) == .waiting)
    expect(altered.observe(echo:"正文 \n",identityStable:true) == .waiting)
    expect(altered.observe(echo:nil,identityStable:true) == .waiting)
}

func reviewedDraftRequiresHumanTargetCheck() {
    let id = "00000000-0000-4000-8000-000000000002"
    let title = "连续表达联通测试 · " + id
    expect(!DesktopTargetVerification.allowsReviewedDraft(bundleID:"com.openai.codex",windowTitle:title,expectedThreadID:id,fieldCount:1,currentValue:"",humanConfirmed:false))
    expect(DesktopTargetVerification.allowsReviewedDraft(bundleID:"com.openai.codex",windowTitle:title,expectedThreadID:id,fieldCount:1,currentValue:"\n",humanConfirmed:true))
    expect(!DesktopTargetVerification.allowsReviewedDraft(bundleID:"com.openai.codex",windowTitle:"其他对话",expectedThreadID:id,fieldCount:1,currentValue:"",humanConfirmed:true))
    expect(!DesktopTargetVerification.allowsReviewedDraft(bundleID:"com.openai.codex",windowTitle:title,expectedThreadID:id,fieldCount:1,currentValue:"未发送的草稿",humanConfirmed:true))
}

func boundDraftRequiresExactLiveConversationID() {
    let a = "00000000-0000-4000-8000-000000000002", b = "00000000-0000-4000-8000-000000000001"
    expect(DesktopTargetVerification.allowsBoundDraft(bundleID:"com.openai.codex",liveLink:"codex://threads/"+a,expectedThreadID:a,fieldCount:1,currentValue:"\n"))
    for link in ["codex://threads/"+b,"codex://threads/"+a+"?host=other","codex://threads/"+a+"#x","codex://user@threads/"+a,"codex://threads:123/"+a,"https://threads/"+a] {
        expect(!DesktopTargetVerification.allowsBoundDraft(bundleID:"com.openai.codex",liveLink:link,expectedThreadID:a,fieldCount:1,currentValue:""))
    }
    expect(!DesktopTargetVerification.allowsBoundDraft(bundleID:"com.openai.codex",liveLink:"codex://threads/"+a,expectedThreadID:a,fieldCount:1,currentValue:"已有草稿"))
    expect(!DesktopTargetVerification.allowsBoundDraft(bundleID:"com.openai.codex",liveLink:nil,expectedThreadID:a,fieldCount:1,currentValue:""))
}

func copyLinkFailureStillRestoresItsOwnClipboardResult() {
    let link = "codex://threads/00000000-0000-4000-8000-000000000002"
    var observation = CopiedLinkObservation(initialChangeCount:10)
    expect(observation.observe(changeCount:11,text:link,windowStable:false) == .targetChanged)
    expect(observation.canRestore(changeCount:11,text:link))
    expect(!observation.canRestore(changeCount:12,text:"用户随后复制的内容"))
    expect(!observation.canRestore(changeCount:12,text:link))
    expect(observation.observe(changeCount:12,text:link,windowStable:true) == .targetChanged)
    var pending = CopiedLinkObservation(initialChangeCount:10)
    expect(pending.observe(changeCount:10,text:link,windowStable:true) == .waiting)
    expect(!pending.canRestore(changeCount:10,text:link))
    expect(pending.observe(changeCount:11,text:link,windowStable:true) == .ready(link))
}

func drawerWaitsAtEdgeAndCancelsAccidentalPass() {
    var state = EdgeDrawerInteraction()
    expect(!state.update(atEdge:true,inside:false,blocked:false,now:0))
    expect(!state.update(atEdge:false,inside:false,blocked:false,now:0.05))
    expect(!state.update(atEdge:true,inside:false,blocked:false,now:1))
    expect(state.update(atEdge:true,inside:false,blocked:false,now:1.13))
}
func drawerLeavingCanBeCancelledAndBlocked() {
    var state = EdgeDrawerInteraction(); state.reveal()
    expect(state.update(atEdge:false,inside:false,blocked:false,now:0))
    expect(state.update(atEdge:false,inside:true,blocked:false,now:0.15))
    expect(state.update(atEdge:false,inside:false,blocked:true,now:1))
    expect(state.update(atEdge:false,inside:false,blocked:false,now:2))
    expect(!state.update(atEdge:false,inside:false,blocked:false,now:2.23))
}
func drawerGeometryFitsNegativeOriginAndSmallScreens() {
    let screen = CGRect(x:-1600,y:80,width:1600,height:900)
    let frame = EdgeDrawerGeometry.frame(in:screen)
    expect(frame.maxX == screen.maxX && frame.minY >= screen.minY && frame.maxY <= screen.maxY)
    expect(abs(frame.width-screen.width/3)<1)
    let small = CGRect(x:20,y:0,width:380,height:400)
    let fit = EdgeDrawerGeometry.frame(in:small)
    expect(small.contains(fit))
}
func drawerSpringSettlesAndRetargetsContinuously() {
    var motion = EdgeDrawerMotion()
    for _ in 0..<30 { motion.step(target:1,dt:1.0/60) }
    expect(motion.position>0.99 && motion.position<=1)
    let before = motion.position
    motion.step(target:0,dt:1.0/60)
    expect(motion.position<before && motion.position>0.8)
    for _ in 0..<90 { motion.step(target:0,dt:1.0/60) }
    expect(motion.position<0.001 && motion.position>=0)
}
func drawerReduceMotionIsImmediateAndBounded() {
    var motion = EdgeDrawerMotion()
    motion.step(target:1,dt:0.01,reduceMotion:true)
    expect(motion.position == 1 && motion.velocity == 0)
    motion.step(target:0,dt:0.01,reduceMotion:true)
    expect(motion.position == 0 && motion.velocity == 0)
}
func drawerExplicitHideResetsPendingHover() {
    var state = EdgeDrawerInteraction(); state.reveal(); state.hide()
    expect(!state.update(atEdge:false,inside:false,blocked:false,now:5))
    expect(!state.update(atEdge:true,inside:false,blocked:false,now:6))
}

func hiddenDrawerCanRecoverWithAttachedDialog() {
    expect(!EdgeDrawerInteraction.isBlocked(visible:false,attachedDialog:true,dragging:false))
    expect(EdgeDrawerInteraction.isBlocked(visible:true,attachedDialog:true,dragging:false))
    expect(EdgeDrawerInteraction.isBlocked(visible:false,attachedDialog:false,dragging:true))
}

func drawerSpringDoesNotDependOnTimerCadence() {
    var oneStep = EdgeDrawerMotion()
    oneStep.step(target:1,dt:1)
    expect(oneStep.position>0.999)
    var interrupted = EdgeDrawerMotion(position:0.4,velocity:0.8)
    interrupted.step(target:0,dt:1.0/120)
    expect(interrupted.position>0.39 && interrupted.position<0.42)
}
func drawerReturnsDuringClosingWithoutEdgeDwell() {
    var state = EdgeDrawerInteraction(); state.reveal()
    _ = state.update(atEdge:false,inside:false,blocked:false,now:0)
    expect(!state.update(atEdge:false,inside:false,blocked:false,now:0.23))
    expect(state.update(atEdge:false,inside:true,blocked:false,now:0.24))
}

func drawerOnlyCurrentCompletionReenablesPointer() {
    var guardState = EdgeDrawerTransitionGuard()
    let hide = guardState.begin(animated:true)
    let reveal = guardState.begin(animated:true)
    expect(guardState.blocksPointer)
    expect(!guardState.complete(hide) && guardState.blocksPointer)
    expect(guardState.complete(reveal) && !guardState.blocksPointer)
}
func drawerReduceMotionDoesNotBlockPointer() {
    var guardState = EdgeDrawerTransitionGuard()
    _ = guardState.begin(animated:false)
    expect(!guardState.blocksPointer)
}

func desktopSendCanOnlyConsumeVerifiedAttemptOnce() {
    var gate = DesktopSendAuthorization()
    expect(gate.consume(identityMatched:true,exactEcho:true,focusStable:true,sendButtonCount:1,buttonEnabled:true,responseActive:false))
    expect(!gate.consume(identityMatched:true,exactEcho:true,focusStable:true,sendButtonCount:1,buttonEnabled:true,responseActive:false))
}
func desktopSendRejectsChangedTargetTextOrFocus() {
    for missing in 0..<3 {
        var gate = DesktopSendAuthorization()
        expect(!gate.consume(identityMatched:missing != 0,exactEcho:missing != 1,focusStable:missing != 2,sendButtonCount:1,buttonEnabled:true,responseActive:false))
    }
}
func desktopSendRejectsAmbiguousDisabledOrBusyControls() {
    for count in [0,2] {
        var gate = DesktopSendAuthorization()
        expect(!gate.consume(identityMatched:true,exactEcho:true,focusStable:true,sendButtonCount:count,buttonEnabled:true,responseActive:false))
    }
    var disabled = DesktopSendAuthorization(), busy = DesktopSendAuthorization()
    expect(!disabled.consume(identityMatched:true,exactEcho:true,focusStable:true,sendButtonCount:1,buttonEnabled:false,responseActive:false))
    expect(!busy.consume(identityMatched:true,exactEcho:true,focusStable:true,sendButtonCount:1,buttonEnabled:true,responseActive:true))
}
func desktopSendAcceptsOnlyExplicitSendButtonLabels() {
    expect(DesktopSendAuthorization.isSendButton(role:"AXButton",label:"发送"))
    expect(DesktopSendAuthorization.isSendButton(role:"AXButton",label:"Send"))
    for label in ["停止","排队","引导","Resume","Send later",""] {
        expect(!DesktopSendAuthorization.isSendButton(role:"AXButton",label:label))
    }
    expect(!DesktopSendAuthorization.isSendButton(role:"AXStaticText",label:"发送"))
}

func desktopSendInvokesActualActionOnce() {
    var gate = DesktopSendAuthorization(), submissions = 0
    // Metadata enumeration is advisory; the verified action is the authority.
    let first = gate.performOnce(identityMatched:true,exactEcho:true,focusStable:true,sendButtonCount:1,buttonEnabled:true,responseActive:false) { submissions += 1; return -25204 }
    let second = gate.performOnce(identityMatched:true,exactEcho:true,focusStable:true,sendButtonCount:1,buttonEnabled:true,responseActive:false) { submissions += 1; return 0 }
    expect(first == -25204 && second == nil && submissions == 1)
}
func desktopSendDoesNotInvokeActionAfterTargetChanges() {
    var gate = DesktopSendAuthorization(), submissions = 0
    let status = gate.performOnce(identityMatched:false,exactEcho:true,focusStable:true,sendButtonCount:1,buttonEnabled:true,responseActive:false) { submissions += 1; return 0 }
    expect(status == nil && submissions == 0)
}

func desktopComposerReusesOnlyExactApprovedDraft() {
    expect(DesktopSendAuthorization.composerDisposition(current:"正文🙂",approved:"正文🙂",allowReuse:true) == .reuseExact)
    expect(DesktopSendAuthorization.composerDisposition(current:"正文🙂",approved:"正文🙂",allowReuse:false) == .reject)
    expect(DesktopSendAuthorization.composerDisposition(current:"\n ",approved:"正文🙂",allowReuse:true) == .writeEmpty)
}
func desktopComposerProtectsDifferentDrafts() {
    for value in ["正文🙂\n","其他草稿","正文🙂 ","正文"] {
        expect(DesktopSendAuthorization.composerDisposition(current:value,approved:"正文🙂",allowReuse:true) == .reject)
    }
    expect(DesktopSendAuthorization.composerDisposition(current:"é",approved:"e\u{301}",allowReuse:true) == .reject)
}

func desktopSubmitShortcutRequiresPlainOpening() {
    expect(DesktopSendAuthorization.allowsShortcutStart(text:"请检查这段代码：\n\n```swift\nprint(1)\n```"))
    for value in ["", "  \n", "```swift\nprint(1)\n```", "~~~\ncode\n~~~", "    code", "\tcode", " \tcode", "  \tcode", "   \tcode", "\n```code"] {
        expect(!DesktopSendAuthorization.allowsShortcutStart(text:value))
    }
}

func draftFocusRequestsOnceAndRequiresStableReadback() {
    var proof = DraftFocusVerification()
    expect(proof.observe(windowStable:true,draftAllowed:true,focused:false) == .requestFocus)
    expect(proof.observe(windowStable:true,draftAllowed:true,focused:false) == .waiting)
    expect(proof.observe(windowStable:true,draftAllowed:true,focused:true) == .waiting)
    expect(proof.observe(windowStable:true,draftAllowed:true,focused:true) == .verified)
}
func draftFocusRejectsWindowOrDraftChanges() {
    for changedWindow in [true,false] {
        var proof = DraftFocusVerification()
        expect(proof.observe(windowStable:!changedWindow,draftAllowed:changedWindow,focused:false) == .changed)
        expect(proof.observe(windowStable:true,draftAllowed:true,focused:true) == .changed)
    }
    var proof = DraftFocusVerification()
    _ = proof.observe(windowStable:true,draftAllowed:true,focused:false)
    expect(proof.observe(windowStable:true,draftAllowed:false,focused:true) == .changed)
}
