import AppKit
import ApplicationServices
import PrototypeCore
import CryptoKit

extension DesktopAccessibilityProbe {
    /// Human-triggered experiment. No private prompt, materials, clipboard, key press or send action.
    func fillSyntheticDraft() {
        let nonce = UUID().uuidString
        let text = "Mac 辅助功能联通测试。请只回复 AX_DRAFT_RECEIVED \(nonce)。不要执行其他任务，不联网，不修改文件。"
        startDraft(text:text,nonce:nonce,reviewed:false)
    }

    func sendReviewedPrompt() {
        guard canFillReviewedDraft, let text = preparedText, let nonce = preparedNonce else { return }
        humanConfirmed = false
        startDraft(text:text,nonce:nonce,reviewed:true)
    }

    private func startDraft(text: String, nonce: String, reviewed: Bool) {
        guard !busy, selectedTarget != nil else { return }
        reportURL = nil
        guard AXIsProcessTrusted() else {
            message = "当前版本尚未获辅助功能授权，请刷新正式入口授权后再试。"; onFillFailure?(); return
        }
        busy = true; message = reviewed ? "正在核对目标并发送，随后检查接收结果…" : "正在核对目标并填入合成草稿。"
        let targetID = targetID, root = root, receiptOnly = receiptOnly
        onWillFill?()
        guard NSWorkspace.shared.open(URL(string:"codex://threads/"+targetID)!) else {
            busy = false; message = "无法打开所选对话，未填写。"; onFillFailure?(); return
        }
        Task {
            try? await Task.sleep(for:.milliseconds(700))
            guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.openai.codex" else {
                busy = false; message = "前台不是 Codex，未填写。"; onFillFailure?(); return
            }
            let pid = app.processIdentifier
            DispatchQueue.global(qos:.userInitiated).async {
                var diagnostics: [String:Any] = [:]
                let outcome = Result {
                    let attempt = reviewed ? try DesktopSendAttempt.prepare(root:root,id:targetID,text:text) : nil
                    try Self.writeDraft(pid:pid,id:targetID,text:text,attempt:attempt,diagnostics:&diagnostics)
                }
                let observations = diagnostics
                Task { @MainActor in
                    self.busy = false
                    var report: [String:Any] = ["mode":reviewed ? "reviewedPromptSend" : "syntheticDraftOnly","expectedThreadID":targetID,"nonce":nonce,
                        "autoSent":observations["receiptVerified"] as? Bool == true,"receiptOnly":receiptOnly,"containsRealPrompt":reviewed,"containsUserMaterials":reviewed,
                        "observations":observations,
                        "payloadSHA256":SHA256.hash(data:Data(text.utf8)).map { String(format:"%02x",$0) }.joined()]
                    report["draftEchoVerified"] = observations["readbackStatus"] as? String == "verified"
                    if observations["submissionReserved"] as? Bool == true && observations["submissionReservationReleased"] as? Bool != true { self.preparedNonce = nil }
                    switch outcome {
                    case .success:
                        self.message = reviewed ? "已发送到所选 Codex 对话，并确认正文已收到。" : "合成草稿已填入，未发送。"
                        if reviewed { self.onDidSend?() }
                    case .failure(let error):
                        report["error"] = error.localizedDescription
                        let attempted = observations["sendAttempted"] as? Bool == true
                        self.message = (attempted ? "发送结果未确认：" : "未发送：")+error.localizedDescription+"。不会自动重试或清空草稿。"
                        self.onFillFailure?()
                        NSApp.activate(ignoringOtherApps:true)
                    }
                    do {
                        let folder = root.appendingPathComponent("AXDiagnostics")
                        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                        let url = folder.appendingPathComponent("draft-"+nonce+".json")
                        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
                        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
                        self.reportURL = url
                    } catch { self.message += " 诊断记录保存失败："+error.localizedDescription }
                }
            }
        }
    }

    nonisolated private static func writeDraft(pid: pid_t, id: String, text: String, attempt: DesktopSendAttempt?, diagnostics: inout [String:Any]) throws {
        func failure(_ message: String) -> NSError { NSError(domain:"AXDraftProbe",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
        func get(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success else { return nil }
            return value
        }
        let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app,0.05)
        guard let initial = get(app,kAXFocusedWindowAttribute) else { throw failure("无法读取焦点窗口") }
        let window = initial as! AXUIElement
        guard let initialTitle = get(window,kAXTitleAttribute) as? String else { throw failure("无法读取当前窗口标题") }
        let deadline = Date().addingTimeInterval(8)
        var queue: [(AXUIElement,Int)] = [(window,0)], cursor = 0, fields: [AXUIElement] = []
        while cursor < queue.count {
            guard cursor < 4000 && Date() < deadline else { throw failure("读取范围不完整") }
            let (element,depth) = queue[cursor]; cursor += 1
            AXUIElementSetMessagingTimeout(element,0.04)
            if get(element,kAXRoleAttribute) as? String == "AXTextArea" { fields.append(element) }
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element,kAXChildrenAttribute as CFString,&raw)
            if status == .success, let children = raw as? [AXUIElement] {
                guard depth < 80 || children.isEmpty else { throw failure("读取深度不完整") }
                queue.append(contentsOf:children.map { ($0,depth+1) })
            } else if status != .attributeUnsupported && status != .noValue { throw failure("无法完整读取窗口") }
        }
        diagnostics["fieldCount"] = fields.count
        guard fields.count == 1, let field = fields.first, let value = get(field,kAXValueAttribute) as? String else {
            throw failure("输入框数量或现有草稿无法安全核对")
        }
        let disposition = DesktopSendAuthorization.composerDisposition(current:value,approved:text,allowReuse:attempt != nil)
        guard disposition != .reject else { throw failure("输入框已有不同草稿，未覆盖或发送") }
        var writable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(field,kAXValueAttribute as CFString,&writable) == .success, writable.boolValue,
              get(field,kAXEnabledAttribute) as? Bool == true else { throw failure("输入框不可编辑") }
        let liveLink = try DesktopConversationIdentity.copiedLink(pid:pid,window:window)
        let idMatches = DesktopTargetVerification.matches(bundleID:NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",documentURL:liveLink,expectedThreadID:id)
        diagnostics["identityBeforeWriteMatched"] = idMatches
        guard idMatches else { throw failure("当前对话 ID 与所选目标不一致，未填写") }
        // Opening an already active chat need not focus its composer. Establish
        // focus explicitly only after exact ID, stable window and draft checks.
        func prewriteSample() -> [String:Any] {
            let current = get(field,kAXValueAttribute) as? String
            let liveWindow = get(app,kAXFocusedWindowAttribute)
            let focused = get(app,kAXFocusedUIElementAttribute)
            return ["frontProcessMatches":NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                    "focusedWindowMatches":liveWindow.map { CFEqual($0,window) } ?? false,
                    "windowTitleMatches":get(window,kAXTitleAttribute) as? String == initialTitle,
                    "focusedFieldMatches":focused.map { CFEqual($0,field) } ?? false,
                    "draftAllowed":current.map { DesktopSendAuthorization.composerDisposition(current:$0,approved:text,allowReuse:attempt != nil) == disposition } ?? false,
                    "currentLength":current?.count ?? -1,
                    "currentSHA256":current.map { SHA256.hash(data:Data($0.utf8)).map { String(format:"%02x",$0) }.joined() } ?? ""]
        }
        var focusProof = DraftFocusVerification(), focusSamples: [[String:Any]] = []
        var focusVerified = false
        let focusDeadline = ProcessInfo.processInfo.systemUptime+1
        while ProcessInfo.processInfo.systemUptime < focusDeadline {
            let sample = prewriteSample(); focusSamples.append(sample)
            diagnostics["prewriteSamples"] = focusSamples
            let windowStable = ["frontProcessMatches","focusedWindowMatches","windowTitleMatches"].allSatisfy { sample[$0] as? Bool == true }
            let status = focusProof.observe(windowStable:windowStable,draftAllowed:sample["draftAllowed"] as? Bool == true,focused:sample["focusedFieldMatches"] as? Bool == true)
            if status == .changed { throw failure("聚焦前窗口或草稿发生变化，未填写") }
            if status == .requestFocus {
                diagnostics["focusRequestAXStatus"] = AXUIElementSetAttributeValue(field,kAXFocusedAttribute as CFString,kCFBooleanTrue).rawValue
            }
            if status == .verified { focusVerified = true; break }
            Thread.sleep(forTimeInterval:0.03)
        }
        guard focusVerified else { throw failure("未能聚焦已核对的输入框，未填写或发送") }
        let immediateLink = try DesktopConversationIdentity.copiedLink(pid:pid,window:window)
        let immediateIDMatches = DesktopTargetVerification.matches(bundleID:NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",documentURL:immediateLink,expectedThreadID:id)
        diagnostics["identityImmediatelyBeforeWriteMatched"] = immediateIDMatches
        guard immediateIDMatches else { throw failure("聚焦后目标对话发生变化，未填写或发送") }
        let finalSample = prewriteSample()
        diagnostics["immediatelyBeforeWrite"] = finalSample
        guard ["frontProcessMatches","focusedWindowMatches","windowTitleMatches","focusedFieldMatches","draftAllowed"].allSatisfy({ finalSample[$0] as? Bool == true }) else {
            throw failure("写入前窗口、焦点或草稿发生变化")
        }
        if disposition == .writeEmpty {
            let writeStatus = AXUIElementSetAttributeValue(field,kAXValueAttribute as CFString,text as CFString)
            diagnostics["writeAXStatus"] = writeStatus.rawValue
            guard writeStatus == .success else { throw failure("系统拒绝填入草稿") }
        } else {
            diagnostics["reusedExactApprovedDraft"] = true
        }
        func observe() -> [String:Any] {
            let echo = get(field,kAXValueAttribute) as? String
            let finalWindow = get(app,kAXFocusedWindowAttribute)
            let finalFocus = get(app,kAXFocusedUIElementAttribute)
            return ["echoReadable":echo != nil,"echoExact":echo.map { $0.utf8.elementsEqual(text.utf8) } ?? false,
                    "echoEqualsTextPlusLF":echo.map { $0.utf8.elementsEqual((text + "\n").utf8) } ?? false,
                    "echoLength":echo?.count ?? -1,
                    "echoSHA256":echo.map { SHA256.hash(data:Data($0.utf8)).map { String(format:"%02x",$0) }.joined() } ?? "",
                    "frontProcessMatches":NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                    "focusedWindowMatches":finalWindow.map { CFEqual($0,window) } ?? false,
                    "focusedFieldMatches":finalFocus.map { CFEqual($0,field) } ?? false,
                    "windowTitleMatches":get(window,kAXTitleAttribute) as? String == initialTitle]
        }
        // AX updates asynchronously. Poll only reads; there is exactly one write above.
        var verification = DraftReadbackVerification(expected:text)
        var samples: [[String:Any]] = []
        let readbackDeadline = ProcessInfo.processInfo.systemUptime + 1.2
        while ProcessInfo.processInfo.systemUptime < readbackDeadline {
            let sample = observe(); samples.append(sample)
            let stable = ["frontProcessMatches","focusedWindowMatches","focusedFieldMatches","windowTitleMatches"].allSatisfy { sample[$0] as? Bool == true }
            let status = verification.observe(echo:sample["echoExact"] as? Bool == true ? text : nil,identityStable:stable)
            diagnostics["postWriteSamples"] = samples
            if status == .verified {
                let endingLink = try DesktopConversationIdentity.copiedLink(pid:pid,window:window)
                let endingMatches = DesktopTargetVerification.matches(bundleID:NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",documentURL:endingLink,expectedThreadID:id)
                diagnostics["identityAfterWriteMatched"] = endingMatches
                guard endingMatches, get(window,kAXTitleAttribute) as? String == initialTitle,
                      get(app,kAXFocusedUIElementAttribute).map({ CFEqual($0,field) }) == true,
                      (get(field,kAXValueAttribute) as? String).map({ $0.utf8.elementsEqual(text.utf8) }) == true else {
                    throw failure("回读后对话或内容发生变化，草稿可能已填入，请人工检查")
                }
                diagnostics["readbackStatus"] = "verified"
                if let attempt { try DesktopMessageSending.submit(pid:pid,id:id,app:app,window:window,field:field,text:text,attempt:attempt,diagnostics:&diagnostics) }
                return
            }
            if status == .targetChanged {
                diagnostics["readbackStatus"] = "targetChanged"
                throw failure("写入后窗口或焦点变化，已停止核对；草稿可能已填入，请人工检查")
            }
            Thread.sleep(forTimeInterval:0.05)
        }
        diagnostics["readbackStatus"] = "timeout"
        throw failure("等待输入框更新超时；草稿可能已填入，请人工检查，不要重复点击")
    }
}
