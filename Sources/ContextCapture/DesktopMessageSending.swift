import AppKit
import ApplicationServices
import CryptoKit
import PrototypeCore

/// The helper only reads Codex history; native UI submission remains human-button triggered.
struct DesktopSendAttempt {
    let folder: URL, journal: URL, threadID: String, sha: String
    static func prepare(root: URL, id: String, text: String) throws -> Self {
        let attempt = Self(folder:root.appendingPathComponent("SendReceipts/"+UUID().uuidString),journal:root.appendingPathComponent("SendJournal"),threadID:id,sha:SHA256.hash(data:Data(text.utf8)).map { String(format:"%02x",$0) }.joined())
        try FileManager.default.createDirectory(at:attempt.folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        _ = try attempt.run("baseline")
        return attempt
    }
    func run(_ mode: String) throws -> [String:Any] {
        let project = Bundle.main.object(forInfoDictionaryKey:"ProjectRoot") as? String ?? ""
        let python = Bundle.main.object(forInfoDictionaryKey:"PythonExecutable") as? String ?? ""
        let codex = Bundle.main.object(forInfoDictionaryKey:"CodexExecutable") as? String ?? ""
        let output = folder.appendingPathComponent(mode+"-"+UUID().uuidString+".json")
        let process = Process(); process.executableURL = URL(fileURLWithPath:python)
        process.arguments = [URL(fileURLWithPath:project).appendingPathComponent("tools/desktop_send_receipt.py").path,mode,"--codex",codex,"--state",folder.appendingPathComponent("baseline.json").path,"--journal",journal.path,"--output",output.path,"--thread",threadID,"--sha",sha]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime+12
        while process.isRunning && ProcessInfo.processInfo.systemUptime<deadline { Thread.sleep(forTimeInterval:0.03) }
        if process.isRunning { process.terminate(); process.waitUntilExit(); throw error("接收核对超时，请查看 Codex；不会自动重发") }
        let result = try JSONSerialization.jsonObject(with:Data(contentsOf:output)) as? [String:Any] ?? [:]
        guard process.terminationStatus == 0 else { throw error(result["error"] as? String ?? "发送前记录或接收核对不可用") }
        return result
    }
    func error(_ message: String) -> NSError { NSError(domain:"DesktopSend",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
}

enum DesktopMessageSending {
    static func submit(pid: pid_t, id: String, app: AXUIElement, window: AXUIElement, field: AXUIElement, text: String, attempt: DesktopSendAttempt, diagnostics: inout [String:Any]) throws {
        func get(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success ? value : nil
        }
        func stable() -> Bool {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid &&
            get(app,kAXFocusedWindowAttribute).map { CFEqual($0,window) } == true &&
            get(app,kAXFocusedUIElementAttribute).map { CFEqual($0,field) } == true
        }
        guard let raw = get(field,kAXParentAttribute), let role = get(raw as! AXUIElement,kAXRoleAttribute) as? String, role == "AXGroup" else {
            throw attempt.error("无法限定当前输入区的发送控件，草稿已保留")
        }
        var queue: [(AXUIElement,Int)] = [(raw as! AXUIElement,0)], cursor = 0, buttons: [AXUIElement] = []
        var fields = 0, busy = false
        let deadline = ProcessInfo.processInfo.systemUptime+3
        while cursor<queue.count {
            guard cursor<1000, ProcessInfo.processInfo.systemUptime<deadline else { throw attempt.error("输入区读取不完整，未点击发送") }
            let (element,depth) = queue[cursor];cursor += 1
            AXUIElementSetMessagingTimeout(element,0.05)
            let role = get(element,kAXRoleAttribute) as? String ?? ""
            if CFEqual(element,field) { fields += 1 }
            let labels = [get(element,kAXTitleAttribute) as? String,get(element,kAXDescriptionAttribute) as? String].compactMap { $0?.trimmingCharacters(in:.whitespacesAndNewlines) }
            if labels.contains(where:{ DesktopSendAuthorization.isSendButton(role:role,label:$0) }) { buttons.append(element) }
            if role == "AXButton", labels.contains(where:{ ["停止","停止响应","Stop","Stop response"].contains($0) }) { busy = true }
            var children: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element,kAXChildrenAttribute as CFString,&children)
            if status == .success, let list = children as? [AXUIElement] {
                guard depth<12 || list.isEmpty else { throw attempt.error("输入区读取过深，未点击发送") }
                queue.append(contentsOf:list.map { ($0,depth+1) })
            } else if status != .attributeUnsupported && status != .noValue { throw attempt.error("无法完整核对发送控件") }
        }
        diagnostics["sendButtonCount"] = buttons.count;diagnostics["responseActive"] = busy
        guard fields == 1, buttons.count == 1, let button = buttons.first else { throw attempt.error("未找到唯一可用的发送按钮，草稿已保留") }
        var actions: CFArray?
        let discoveryStatus = AXUIElementCopyActionNames(button,&actions)
        diagnostics["sendActionDiscoveryStatus"] = discoveryStatus.rawValue
        diagnostics["sendAdvertisedActions"] = (actions as? [String]) ?? []
        // The installed Codex registers composer.submitInBackground as
        // CmdOrCtrl+Enter. Use the verified focused composer, not its AX menu.
        guard DesktopSendAuthorization.allowsShortcutStart(text:text) else {
            throw attempt.error("Prompt 开头是代码段或不支持的格式，请先在侧栏最前面写一句自然语言要求，再发送")
        }
        guard stable(), (get(field,kAXValueAttribute) as? String)?.utf8.elementsEqual(text.utf8) == true else {
            throw attempt.error("准备提交位置时窗口或正文发生变化，未发送")
        }
        var start = CFRange(location:0,length:0)
        guard let selection = AXValueCreate(.cfRange,&start),
              AXUIElementSetAttributeValue(field,kAXSelectedTextRangeAttribute as CFString,selection) == .success,
              selectionAtStart(field) else {
            diagnostics["submitSelectionAtStart"] = false
            throw attempt.error("无法核对提交时的输入位置，未发送")
        }
        diagnostics["submitSelectionAtStart"] = true
        let (submitDown,submitUp) = try submitKeyEvents()
        diagnostics["sendRoute"] = "codexCommandReturn"
        var reserved = false, pressed = false
        defer {
            if reserved && !pressed {
                let released = try? attempt.run("release")
                diagnostics["submissionReservationReleased"] = released?["released"] as? Bool == true
            }
        }
        // Keep all actual or ambiguous press attempts reserved. Release only a
        // reservation owned by this attempt when no submit event was dispatched.
        _ = try attempt.run("reserve"); reserved = true; diagnostics["submissionReserved"] = true
        let link = try DesktopConversationIdentity.copiedLink(pid:pid,window:window)
        let matched = DesktopTargetVerification.matches(bundleID:NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",documentURL:link,expectedThreadID:id)
        let exact = (get(field,kAXValueAttribute) as? String).map { $0.utf8.elementsEqual(text.utf8) } == true && selectionAtStart(field)
        let liveLabels = [get(button,kAXTitleAttribute) as? String,get(button,kAXDescriptionAttribute) as? String].compactMap { $0?.trimmingCharacters(in:.whitespacesAndNewlines) }
        let stillSend = liveLabels.contains { DesktopSendAuthorization.isSendButton(role:get(button,kAXRoleAttribute) as? String ?? "",label:$0) }
        var gate = DesktopSendAuthorization()
        diagnostics["identityBeforeSendMatched"] = matched
        let status = gate.performOnce(identityMatched:matched,exactEcho:exact,focusStable:stable(),sendButtonCount:buttons.count,buttonEnabled:stillSend && get(button,kAXEnabledAttribute) as? Bool == true,responseActive:busy) {
            pressed = true
            diagnostics["sendAttempted"] = true
            submitDown.postToPid(pid); submitUp.postToPid(pid)
            diagnostics["submitKeyEventsDispatched"] = true
            return 0 // Event dispatch is not acceptance; require the new-message receipt.
        }
        guard let status else { throw attempt.error("发送前目标、内容、焦点或按钮发生变化，未点击发送") }
        diagnostics["localDispatchCompleted"] = status == 0
        // Never repeat the shortcut, even when the receipt is delayed.
        let receipt = try attempt.run("confirm")
        diagnostics["receiptVerified"] = receipt["receiptVerified"] as? Bool == true
        if let turn = receipt["turnID"] as? String { diagnostics["receivedTurnID"] = turn }
        guard receipt["receiptVerified"] as? Bool == true else { throw attempt.error("已尝试发送，但暂未查到匹配的新消息；请查看 Codex，不会重发") }
    }
    private static func selectionAtStart(_ field: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field,kAXSelectedTextRangeAttribute as CFString,&raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
        var range = CFRange(location:-1,length:-1)
        return AXValueGetValue(raw as! AXValue,.cfRange,&range) && range.location == 0 && range.length == 0
    }
    /// The pair is created before reservation; it is only posted by the one-shot
    /// action after fresh ID, exact text, focused-window/field and readiness checks.
    static func submitKeyEvents() throws -> (CGEvent,CGEvent) {
        guard let source = CGEventSource(stateID:.privateState),
              let down = CGEvent(keyboardEventSource:source,virtualKey:36,keyDown:true),
              let up = CGEvent(keyboardEventSource:source,virtualKey:36,keyDown:false) else {
            throw NSError(domain:"DesktopSend",code:1,userInfo:[NSLocalizedDescriptionKey:"无法创建 Codex 提交快捷键，未发送"])
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        return (down,up)
    }
}
