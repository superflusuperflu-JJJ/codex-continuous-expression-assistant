import AppKit
import struct SwiftUI.Binding
import Foundation
import AVFoundation
import CoreMedia
import PrototypeCore

extension SessionModel {
    static func integrationChecks() -> Int {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("capture-check-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temp) }
        let model = SessionModel(rootOverride:temp,startServices:false)
        model.directory = temp
        model.sessionID = "fixture"; model.phase = "capturing"; model.voiceEnabled = false
        var failures = 0, checks = 0
        func check(_ value: Bool, _ name: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        do {
            let (down,up) = try DesktopMessageSending.submitKeyEvents()
            check(down.type == .keyDown && up.type == .keyUp && down.getIntegerValueField(.keyboardEventKeycode) == 36 && up.getIntegerValueField(.keyboardEventKeycode) == 36,
                  "提交事件严格为 Return 按下和抬起一对，不重复发送")
            let modifiers: CGEventFlags = [.maskCommand,.maskControl,.maskAlternate,.maskShift]
            check(down.flags.intersection(modifiers) == .maskCommand && up.flags.intersection(modifiers) == .maskCommand,
                  "提交两端明确携带 Command，避免成为普通换行或其他快捷键")
        } catch { check(false,"创建提交按键失败") }
        // Real NSTextView edits exercise selection and reentrant model updates.
        // Rewriting the storage during textDidChange must fail these checks.
        let editorModel = SessionModel(rootOverride:temp,startServices:false)
        editorModel.prompt = "开头🙂中间结尾"
        let editor = PromptTextEditor(text:Binding(get:{editorModel.prompt},set:{editorModel.editPrompt($0)}))
        let coordinator = editor.makeCoordinator()
        let textView = coordinator.makeTextView()
        coordinator.synchronize(editorModel.prompt, in:textView)
        textView.setSelectedRange(NSRange(location:4,length:0))
        coordinator.synchronize(editorModel.prompt, in:textView)
        check(textView.selectedRange() == NSRange(location:4,length:0), "页面刷新保留 UTF16 光标位置")
        coordinator.text = Binding(get:{editorModel.prompt},set:{ value in
            // A published page refresh may still carry its previous snapshot.
            coordinator.synchronize(editorModel.prompt, in:textView)
            editorModel.editPrompt(value)
        })
        textView.insertText("新",replacementRange:textView.selectedRange())
        check(textView.string == "开头🙂新中间结尾" && editorModel.prompt == textView.string && textView.selectedRange().location == 5,
              "中间插入文本与同步刷新不会把光标推到末尾")
        textView.setSelectedRange(NSRange(location:5,length:2))
        textView.insertText("改",replacementRange:textView.selectedRange())
        check(textView.string == "开头🙂新改结尾" && textView.selectedRange().location == 6,
              "选区替换保留用户输入位置")
        textView.deleteBackward(nil)
        check(textView.string == "开头🙂新结尾" && editorModel.prompt == textView.string && textView.selectedRange().location == 5,
              "中间退格删除后光标不跳转")
        textView.setMarkedText("zhong",selectedRange:NSRange(location:5,length:0),replacementRange:NSRange(location:5,length:0))
        coordinator.synchronize("过期刷新",in:textView)
        check(textView.hasMarkedText() && textView.string.contains("zhong"), "中文候选组合期间刷新不打断输入法")
        textView.insertText("中",replacementRange:textView.markedRange())
        check(textView.string == "开头🙂新中结尾" && editorModel.prompt == textView.string && textView.selectedRange().location == 6,
              "中文组合提交保留中间插入位置")
        coordinator.synchronize("短",in:textView)
        check(textView.string == "短" && textView.selectedRange().location <= 1,
              "外部更新正文时安全收敛选区")
        do {
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
            let url = temp.appendingPathComponent("recording.caf")
            let file = try SpeechCapture.recordingFile(at: url, format: format)
            let matches = file.processingFormat == format
            check(matches, "录音写入格式匹配识别器 Int16 缓冲区")
            if matches {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320)!
                buffer.frameLength = 320
                try file.write(from: buffer)
                file.close()
                check(try AVAudioFile(forReading: url).length == 320, "识别器格式音频可以写入并读回")
            } else { check(false, "识别器格式音频可以写入并读回") }
        } catch { check(false, "录音格式回归：\(error)") }
        var audioClock = AudioInputClock()
        let firstAudio = audioClock.start(hostOffset: 0.001, frames: 321, sampleRate: 16000)
        let secondAudio = audioClock.start(hostOffset: 0.021, frames: 320, sampleRate: 16000)
        check(CMTimeCompare(secondAudio, CMTimeAdd(firstAudio, CMTime(value: 321, timescale: 16000))) >= 0,
              "转换后音频按实际帧数计时，不发生块间重叠")
        model.receiveSpeech(SpokenSegment(id: "1.7393", text: "这个改大", start: 1.73932, end: 3), final: false)
        model.receiveSpeech(SpokenSegment(id: "1.7394", text: "这个改大。", start: 1.73936, end: 3), final: true)
        check(model.segments.count == 1 && model.segments.first?.text == "这个改大。", "最终识别的微小时间修正替换临时句子")
        model.receiveSpeech(SpokenSegment(id: "4", text: "这个改大。", start: 4, end: 5), final: true)
        check(model.segments.count == 2, "用户在不同时间主动重复的要求仍保留")
        let canonical = SpokenSegment(id:"final-0",text:"这个改得简短一点。",start:1.8,end:3,
            words:[TimedWord("这个",start:1.8,end:2.1)])
        model.applyFinalTranscript(SpeechReview(segments:[canonical],spans:[AudioSpan(audioStart:0,audioEnd:3,hostStart:1)]))
        check(model.segments.count == 1 && model.segments.first?.text == "这个改得简短一点。", "完整录音结果替换临时碎片，不按字符串删重猜测原话")
        check(model.segments.first?.words.first?.start == 1.8 && FileManager.default.fileExists(atPath:temp.appendingPathComponent("audio-timeline.json").path), "最终转写保留词级时间与录音映射证据")
        model.prepareReview()
        check(model.gaps.contains(where:{$0.contains("没有收到任何素材")}), "口述引用素材却零采集时明确提示采集缺口")
        model.segments = []; model.gaps = []
        let now = clockNow()
        let text = String(repeating:"这是一段不能丢失的正文。",count:40)
        let message: [String:Any] = ["type":"selection","session":"fixture","kind":"link","occurredAt":now-1,
            "source":"https://example.com/a","content":"https://example.com/reference","selectedText":text,
            "label":text,"links":[["label":"参考","url":"https://example.com/reference"]],"tabID":1,"documentID":"a"]
        var accepted = false
        model.browserMessage(message) { accepted = $0["ok"] as? Bool == true }
        check(accepted && model.materials.contains(where:{$0.content == text}),"包含链接的长文字完整保留")
        check(model.materials.contains(where:{$0.kind == "链接"}),"链接作为附加素材保留")
        var switched = message; switched["selectedText"] = "采集后已经切换到其他应用的选区"; switched["occurredAt"] = now-0.9
        model.browserMessage(switched) { accepted = $0["ok"] as? Bool == true }
        check(accepted && model.materials.contains(where:{$0.content == "采集后已经切换到其他应用的选区"}),"前台切换后仍接纳原页面已采集事件")
        var drag = switched; drag["selectedText"] = "Clash Verge"; drag["kind"] = "text"; drag["links"] = []
        drag["selectionID"] = "drag"; drag["selectionComplete"] = false; drag["selectionStart"] = now-0.9; drag["occurredAt"] = now-0.8
        model.browserMessage(drag) { accepted = $0["ok"] as? Bool == true }
        check(accepted && model.anchors.last?.selectionID == "drag" && model.anchors.last?.selectionStart == now-0.9,
            "浏览器拖选编号与同钟起点完整进入原始证据")
        drag["selectionComplete"] = true; drag["occurredAt"] = now-0.75
        model.browserMessage(drag) { accepted = $0["ok"] as? Bool == true }
        check(accepted && model.anchors.last?.selectionComplete == true, "最终文字相同也保留松开完成标记，不被去重吞掉")
        try? FileManager.default.createDirectory(at:temp.appendingPathComponent("assets"),withIntermediateDirectories:true)
        var imageMessage: [String:Any] = ["type":"selection","session":"fixture","kind":"image","occurredAt":now-0.7,
            "source":"https://example.com/a","content":"https://example.com/image.png","label":"同一图片", "tabID":1,"documentID":"a"]
        model.browserMessage(imageMessage) { _ in }
        imageMessage["screenshot"] = "data:image/jpeg;base64," + Data("visual-a".utf8).base64EncodedString()
        model.browserMessage(imageMessage) { _ in }
        imageMessage["screenshot"] = "data:image/jpeg;base64," + Data("visual-b".utf8).base64EncodedString()
        model.browserMessage(imageMessage) { _ in }
        let images = model.materials.filter { $0.kind == "图片" }
        check(images.count == 3 && images.filter { $0.localPath != nil }.count == 2, "同一图片链接失败重试和视觉变化分别保留证据版本")
        model.applyAXSelection(nil,at:now-0.5,source:"test")
        let refs = Association.bindings(for:SpokenSegment(text:"这个",start:now,end:now+0.1),anchors:model.anchors)
        check(refs.allSatisfy{!$0.certain},"选区读取未知时旧素材不再确定绑定")
        model.phase = "finalizing"; model.cutoff = now-0.2
        var late = message; late["content"] = "new"; late["selectedText"] = "结束前已选中的内容"; late["occurredAt"] = now-0.3
        model.browserMessage(late) { accepted = $0["ok"] as? Bool == true }
        check(accepted && model.materials.contains(where:{$0.content == "结束前已选中的内容"}),"结束前发出、结束后到达仍纳入")
        late["occurredAt"] = now+0.1
        model.browserMessage(late) { accepted = $0["ok"] as? Bool == true }
        check(!accepted,"截止后新内容不注入旧草稿")
        model.phase = "reviewing"; model.prompt = "用户已经删除旧要求，只保留 M2。"
        model.save()
        let manifestData = try? Data(contentsOf:temp.appendingPathComponent("manifest.json"))
        let manifest = manifestData.flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
        check(manifest?["canonicalText"] as? String == model.prompt && manifest?["structuredStatus"] as? String == "staleAfterUserEdit","自由编辑后正文成为交付真值")
        let editedContext = model.refinementContext()
        check(editedContext.speech.count == 1 && editedContext.speech.first?.id == "edited-draft" && editedContext.speech.first?.text == model.prompt,
            "手动修改后的正文成为再次整理的唯一要求来源")
        check(editedContext.materials.isEmpty, "再次整理不会带回用户已删除的旧素材内容")
        model.segments = [SpokenSegment(id:"requirement",text:"请改短说明",start:1,end:2)]
        model.anchors = []; model.prepareReview(); let snapshot = model.prompt
        let context = model.refinementContext()
        let result = OrganizedPrompt(paragraphs:[PromptParagraph(text:"请缩短说明文字。",speechIDs:["requirement"],materialIDs:[])],decisions:[SpeechDecision("requirement","included")])
        model.prompt = "用户在整理过程中新增的文字。"
        do { try model.acceptRefinement(result,context:context,snapshot:snapshot) } catch { check(false,"异步整理验证失败") }
        check(model.prompt == "用户在整理过程中新增的文字。" && FileManager.default.fileExists(atPath:temp.appendingPathComponent("prompt-suggestion.md").path),
            "异步整理不覆盖用户同时进行的编辑，建议另存")
        do { try model.acceptRefinement(result,context:context,snapshot:model.prompt) } catch { check(false,"整理验证失败") }
        check(model.organizationState == "organized" && model.prompt.contains("请缩短说明文字。"), "经过来源验证的整理结果成为正文")
        check(model.refinementContext().speech.first?.id == "edited-draft" && model.refinementContext().speech.first?.text == model.prompt,
            "成功整理后的再次整理继续使用当前正文，不恢复原始旧要求")
        check(FileManager.default.fileExists(atPath:temp.appendingPathComponent("evidence.md").path) && FileManager.default.fileExists(atPath:temp.appendingPathComponent("organized-request.json").path),
            "完整原始证据和结构化要求分别保留")
        let resolutionJSON = #"{"id":"style","question":"如何缩短说明？","reason":"原话要求简短","speechIDs":["requirement"],"options":[{"label":"简明表达","text":"请用两句话介绍。","materialIDs":[]}],"applyByDefault":false}"#
        let resolution = try! JSONDecoder().decode(PromptResolution.self,from:Data(resolutionJSON.utf8))
        let withChoices = OrganizedPrompt(paragraphs:[],decisions:[SpeechDecision("requirement","unresolved")],resolutions:[resolution])
        do { try model.acceptRefinement(withChoices,context:context,snapshot:model.prompt) } catch { check(false,"选择结果验证失败") }
        check(FileManager.default.fileExists(atPath:temp.appendingPathComponent("review-choices.json").path), "选择卡片状态独立持久化")
        model.prompt += "\n\n保留我手写的限制。"
        model.chooseAllRecommended()
        check(model.prompt.contains("请用两句话介绍。") && model.prompt.contains("保留我手写的限制。"), "批量采用本地更新对应要求，保留手写段落")
        model.choose("style",option:nil,custom:"说明控制在一句话。")
        check(model.prompt.contains("说明控制在一句话。") && !model.prompt.contains("请用两句话介绍。"), "自填完整要求替换已采用的选项")
        model.prompt = model.prompt.replacingOccurrences(of:"说明控制在一句话。",with:"已手动删除这项，不要恢复。")
        let manuallyEdited = model.prompt
        model.choose("style",option:0)
        check(model.prompt == manuallyEdited && model.reviewChoices.first?.conflict == true, "选项不会覆盖或恢复用户改写的要求")
        model.save()
        let savedChoices = try? JSONDecoder().decode([ReviewChoice].self,from:Data(contentsOf:temp.appendingPathComponent("review-choices.json")))
        check(savedChoices?.first?.customText == "说明控制在一句话。" && savedChoices?.first?.conflict == true, "自填答案和编辑冲突可从保存文件恢复")
        let restoredFolder = temp.appendingPathComponent("Sessions/fixture")
        try? FileManager.default.createDirectory(at:restoredFolder,withIntermediateDirectories:true)
        for name in ["materials.json","transcript.json","anchors.json","manifest.json","prompt.md","review-choices.json"] {
            try? FileManager.default.copyItem(at:temp.appendingPathComponent(name),to:restoredFolder.appendingPathComponent(name))
        }
        let restoredModel = SessionModel(rootOverride:temp,startServices:false)
        restoredModel.loadLatestSession()
        check(restoredModel.prompt == manuallyEdited && restoredModel.reviewChoices.first?.customText == "说明控制在一句话。" && restoredModel.reviewChoices.first?.conflict == true, "重开会话保留正文、自填答案和保护状态")
        model.refining = true; let priorSession = model.sessionID; model.start()
        check(model.sessionID == priorSession && model.phase == "reviewing", "整理过程中全局开始操作不能切换会话")
        model.refining = false
        model.prompt = "用户已经删除旧要求，只保留 M2。"
        model.start()
        let saved = try? String(contentsOf:temp.appendingPathComponent("prompt.md"),encoding:.utf8)
        check(saved == "用户已经删除旧要求，只保留 M2。","开始下一段前保存已编辑正文")
        let probe = DesktopAccessibilityProbe(root:temp)
        check(!probe.receiptOnly,"正常入口默认不添加接收测试说明")
        let conversations = try! JSONDecoder().decode([DesktopConversation].self,from:Data("[{\"id\":\"00000000-0000-4000-8000-000000000002\",\"name\":\"同名\",\"cwd\":\"/one\",\"updatedAt\":1},{\"id\":\"00000000-0000-4000-8000-000000000001\",\"name\":\"同名\",\"cwd\":\"/two\",\"updatedAt\":2}]".utf8))
        probe.conversations = conversations
        probe.selectedID = conversations[0].id; probe.humanConfirmed = true; probe.openedForReview = true
        probe.selectedID = conversations[1].id
        check(!probe.humanConfirmed && !probe.openedForReview && probe.targetID == conversations[1].id,"同名对话切换必须按 ID 绑定并清除先前核对")
        probe.humanConfirmed = true; probe.openedForReview = true; probe.search = "不存在的对话"
        check(!probe.humanConfirmed && !probe.openedForReview && probe.selectedID == conversations[1].id,"搜索仅过滤列表，不清除用户固定的目标")
        check((try? FileManager.default.attributesOfItem(atPath:temp.appendingPathComponent("codex-selected-target.json").path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              "固定目标只保存到本机私有文件")
        let reopenedProbe = DesktopAccessibilityProbe(root:temp)
        check(reopenedProbe.targetID == conversations[1].id, "重启恢复固定对话完整 ID，同名目标不混淆")
        probe.conversations = [conversations[0]]
        check(probe.targetID == conversations[1].id, "刷新首页未包含固定目标时不转选其他对话")
        probe.busy = true
        probe.selectedID = conversations[0].id
        check(probe.targetID == conversations[1].id, "准备或发送期间禁止更换固定目标")
        probe.busy = false
        probe.conversations = conversations
        probe.preparedText = "旧预览"; probe.preparedNonce = "旧校验码"; probe.humanConfirmed = true; probe.openedForReview = true
        probe.receiptOnly = true
        check(probe.preparedText == nil && probe.preparedNonce == nil && !probe.humanConfirmed && !probe.openedForReview,"切换接收验证模式后必须重新准备和核对预览")
        probe.search = ""; probe.selectedID = conversations[0].id
        probe.preparedText = "用户已检查的正文"; probe.preparedNonce = "local-attempt"
        probe.humanConfirmed = false; probe.openedForReview = false
        check(probe.canFillReviewedDraft,"选好目标和预览即可一次点击自动核对填入，无需事先切回勾选")
        probe.busy = true
        check(!probe.canFillReviewedDraft,"填入处理中禁止重复发起")
        probe.busy = false; probe.selectedID = nil
        check(!probe.canFillReviewedDraft,"未选对话时禁止填入")
        probe.selectedID = conversations[0].id; probe.preparedText = "  \n "
        check(!probe.canFillReviewedDraft,"空预览禁止填入")
        let settingSuite = "ContextCapture.EdgeDrawerChecks."+UUID().uuidString
        let testDefaults = UserDefaults(suiteName:settingSuite)!
        let initialSettings = EdgePanelSettings(defaults:testDefaults)
        check(!initialSettings.enabled,"右侧自动隐藏首次默认关闭")
        initialSettings.enabled = true
        check(EdgePanelSettings(defaults:testDefaults).enabled,"右侧自动隐藏设置可跨实例保留")
        testDefaults.removePersistentDomain(forName:settingSuite)
        print("\(checks) native integration checks; \(failures) failed")
        return failures
    }
}


extension SessionModel {
    static func compositionSample(executable: String, output: URL, source: URL? = nil) -> Int {
        let words = ["这段文字改短一点。", "简短一点就行。", "先把按钮改成红色。", "不，按钮还是保持绿色。", "图片只用来参考按钮布局。", "这两个文件作为参考，不要修改原文件。"]
        let materials = [Material(id:"M1",kind:"文字",label:"按钮说明",source:"fixture",content:"这是一段需要修改的按钮说明文字"),
            Material(id:"M2",kind:"图片",label:"布局示例",source:"fixture",content:"image"),
            Material(id:"M3",kind:"文件",label:"示例A.txt",source:"fixture",content:"fileA"),
            Material(id:"M4",kind:"文件",label:"示例B.txt",source:"fixture",content:"fileB")]
        var context = PromptComposition.context(materials:materials,segments:[],anchors:[],gaps:[])
        context.speech = words.enumerated().map { index, text in
            let ids = index < 4 ? ["M1"] : index == 4 ? ["M2"] : ["M3","M4"]
            return PromptSpeech(id:"s\(index)",text:text,bindings:[],selectedMaterialIDs:ids)
        }
        do {
            if let source {
                let decoder = JSONDecoder()
                let items = try decoder.decode([Material].self,from:Data(contentsOf:source.appendingPathComponent("materials.json")))
                let speech = try decoder.decode([SpokenSegment].self,from:Data(contentsOf:source.appendingPathComponent("transcript.json")))
                let points = try decoder.decode([Anchor].self,from:Data(contentsOf:source.appendingPathComponent("anchors.json")))
                context = PromptComposition.context(materials:items,segments:speech,anchors:points,gaps:[])
            }
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            try JSONEncoder().encode(context).write(to:output.appendingPathComponent("context.json"))
            let result = try PromptRefinement.run(context:context,executable:executable,directory:output,job:RefinementJob())
            let rendered = PromptComposition.render(result,context:context)
            try rendered.write(to:output.appendingPathComponent("prompt.md"),atomically:true,encoding:.utf8)
            print(rendered)
            return 0
        } catch { print("COMPOSITION_FAILED: \(error.localizedDescription)"); return 1 }
    }
}
