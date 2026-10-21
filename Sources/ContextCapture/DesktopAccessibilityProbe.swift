import AppKit
import ApplicationServices
import Combine
import CryptoKit
import PrototypeCore
import SwiftUI

/// Human-triggered delivery of the reviewed editor snapshot. Normal user button sends only after target verification.
@MainActor final class DesktopAccessibilityProbe: ObservableObject {
    @Published var conversations: [DesktopConversation] = []
    private var pinnedTarget: DesktopConversation?
    private var revertingSelection = false
    @Published var selectedID: String? {
        didSet {
            guard !revertingSelection else { return }
            guard !busy else {
                revertingSelection = true; selectedID = oldValue; revertingSelection = false
                return
            }
            guard selectedID != oldValue else { return }
            humanConfirmed = false; openedForReview = false; reportURL = nil
            if let row = conversations.first(where:{ $0.id == selectedID }) {
                pinnedTarget = row
                message = "已固定发送目标，之后将持续发送到这个对话。"
                persistTarget(row)
            } else if selectedID == nil {
                pinnedTarget = nil
                try? FileManager.default.removeItem(at:targetFile)
            }
        }
    }
    @Published var search = "" { didSet { humanConfirmed = false; openedForReview = false } }
    var nextCursor: String?
    var selectedTarget: DesktopConversation? {
        guard let selectedID else { return nil }
        return conversations.first { $0.id == selectedID } ?? (pinnedTarget?.id == selectedID ? pinnedTarget : nil)
    }
    var targetID: String { selectedTarget?.id ?? "" }
    var targetTitle: String { selectedTarget?.name ?? "请先选择对话" }
    var filteredConversations: [DesktopConversation] { conversations.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.cwd.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) } }
    let root: URL
    @Published var busy = false
    @Published var message = "请选择发送目标，选定后将持续使用该对话。"
    @Published var reportURL: URL?
    @Published var preparedText: String?
    @Published var includedIDs: [String] = []
    @Published var humanConfirmed = false
    @Published var openedForReview = false
    @Published var receiptOnly = false {
        didSet { preparedText = nil; preparedNonce = nil; humanConfirmed = false; openedForReview = false; includedIDs = [] }
    }
    var onDidSend: (() -> Void)?
    var onWillFill: (() -> Void)?
    var onFillFailure: (() -> Void)?
    var preparedNonce: String?
    var canFillReviewedDraft: Bool {
        !busy && selectedTarget != nil && preparedText?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false && preparedNonce != nil
    }
    private(set) var sourceSession: URL?
    private(set) var sourcePrompt: String
    private(set) var sourceMaterials: [PrototypeCore.Material]
    init(root: URL, session: URL? = nil, prompt: String = "", materials: [PrototypeCore.Material] = []) {
        self.root = root; sourceSession = session; sourcePrompt = prompt; sourceMaterials = materials
        if let data = try? Data(contentsOf:root.appendingPathComponent("codex-selected-target.json")),
           let saved = try? JSONDecoder().decode(DesktopConversation.self,from:data), UUID(uuidString:saved.id) != nil {
            pinnedTarget = saved; selectedID = saved.id
        }
    }

    private var targetFile: URL { root.appendingPathComponent("codex-selected-target.json") }
    private func persistTarget(_ row: DesktopConversation) {
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try JSONEncoder().encode(row).write(to:targetFile,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:targetFile.path)
        } catch { message = "目标已选定，但保存失败；重启后需要重新选择。" }
    }
    func sendCurrentPrompt(session: URL?, prompt: String, materials: [PrototypeCore.Material]) {
        guard !busy, selectedTarget != nil, session != nil, !prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        sourceSession = session; sourcePrompt = prompt; sourceMaterials = materials
        receiptOnly = false
        let intendedTarget = targetID
        prepareDraft { [weak self] in
            guard let self else { return }
            guard self.targetID == intendedTarget else {
                self.message = "准备期间目标发生变化，已停止，未填写或发送。"
                return
            }
            self.sendReviewedPrompt()
        }
    }

    func permission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
    func inspect() {
        guard !busy, selectedTarget != nil else { return }
        guard AXIsProcessTrusted() else {
            message = "原型尚未获得辅助功能权限。请点“允许辅助功能”，由你在系统设置中开启后再检查。"; return
        }
        busy = true; reportURL = nil
        message = "正在打开专用测试对话并检查；期间会短暂切换到 Codex。不会输入或发送消息。"
        guard NSWorkspace.shared.open(URL(string:"codex://threads/"+targetID)!) else {
            busy = false; message = "系统未能打开指定对话，已停止。"; return
        }
        Task {
            try? await Task.sleep(for:.milliseconds(700))
            guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.openai.codex" else {
                busy = false; message = "前台不是 Codex，已停止检查；没有填写或发送。"; return
            }
            let pid = app.processIdentifier, targetID = targetID, title = targetTitle, root = root
            DispatchQueue.global(qos:.userInitiated).async {
                let report = Self.snapshot(pid:pid,expectedID:targetID,expectedTitle:title)
                Task { @MainActor in
                    self.busy = false
                    var report = report
                    let sameFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                    report["frontmostUnchanged"] = sameFront
                    report["identityVerified"] = false // A snapshot is not a live pre-send identity check.
                    do {
                        let folder = root.appendingPathComponent("AXDiagnostics")
                        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                        let url = folder.appendingPathComponent(UUID().uuidString+".json")
                        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
                        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
                        self.reportURL = url
                        let count = report["nodeCount"] as? Int ?? 0
                        let proven = sameFront && (report["snapshotURLMatchesTarget"] as? Bool == true)
                        self.message = "只读检查完成（\(count) 个节点，发现 \(report["textFieldCount"] as? Int ?? 0) 个输入控件）。" + (proven ? "快照 URL 匹配目标；尚未做发送前的实时核对，未填写或发送。" : "尚未取得可靠的当前对话标识，不允许自动填写或发送。")
                    } catch { self.message = "诊断报告保存失败："+error.localizedDescription }
                    // Return to the user-triggered diagnostic panel, not an arbitrary work chat.
                    NSApp.activate(ignoringOtherApps:true)
                }
            }
        }
    }
    nonisolated private static func snapshot(pid: pid_t, expectedID: String, expectedTitle: String) -> [String:Any] {
        let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app,0.06)
        func get(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success else { return nil }
            return value
        }
        var report: [String:Any] = ["schemaVersion":1,"expectedThreadID":expectedID,"expectedTitle":expectedTitle,
            "permissionGranted":true,"pid":pid,"identityVerified":false,"mode":"readOnly","sent":false]
        guard let focused = get(app,kAXFocusedWindowAttribute) else {
            report["error"] = "无法取得 Codex 焦点窗口"; report["nodeCount"] = 0; return report
        }
        let window = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(window,0.06)
        let deadline = Date().addingTimeInterval(8)
        var queue: [(AXUIElement,Int,Int)] = [(window,0,-1)], cursor = 0
        var nodes: [[String:Any]] = [], documentURLs: [String] = []
        var fieldCount = 0, webAreaCount = 0, childReadFailures = 0, complete = true
        while cursor < queue.count {
            if nodes.count >= 4000 || Date() > deadline { complete = false; break }
            let (element,depth,parent) = queue[cursor]; cursor += 1
            AXUIElementSetMessagingTimeout(element,0.04)
            let role = get(element,kAXRoleAttribute) as? String ?? "unknown"
            var node: [String:Any] = ["index":nodes.count,"parent":parent,"depth":depth,"role":role]
            for key in [kAXSubroleAttribute,kAXTitleAttribute,kAXDescriptionAttribute,kAXIdentifierAttribute] {
                if let value = get(element,key) as? String, !value.isEmpty {
                    node[key] = AXDiagnosticEvidence.safeLabel(value,targetTitle:expectedTitle)
                    node[key+"ContainsExpectedThreadID"] = value.contains(expectedID)
                }
            }
            for key in [kAXEnabledAttribute,kAXFocusedAttribute,kAXSelectedAttribute] {
                if let value = get(element,key) as? Bool { node[key] = value }
            }
            if let value = get(element,kAXValueAttribute) as? String {
                node["valueLength"] = value.count
                node["valueSHA256"] = SHA256.hash(data:Data(value.utf8)).map { String(format:"%02x",$0) }.joined()
                if value == expectedTitle { node["valueMatchesTargetTitle"] = true }
            }
            if role == "AXWebArea" {
                webAreaCount += 1
                if let value = get(element,kAXURLAttribute), let url = (value as? URL)?.absoluteString ?? (value as? String) {
                    documentURLs.append(url)
                    let matches = DesktopTargetVerification.matches(bundleID:"com.openai.codex",documentURL:url,expectedThreadID:expectedID)
                    node["documentURLMatchesTarget"] = matches
                    let components = URLComponents(string:url)
                    node["documentURLScheme"] = components?.scheme ?? "unknown"
                    node["documentURLContainsExpectedThreadID"] = url.contains(expectedID)
                    node["documentURLPathContainsExpectedThreadID"] = components?.path.split(separator:"/").contains(Substring(expectedID)) ?? false
                    node["documentURLQueryContainsExpectedThreadID"] = components?.queryItems?.contains(where:{ $0.value == expectedID }) ?? false
                    node["documentURLFragmentContainsExpectedThreadID"] = components?.fragment?.contains(expectedID) ?? false
                    node["documentURLLength"] = url.count
                    node["documentURLSHA256"] = SHA256.hash(data:Data(url.utf8)).map { String(format:"%02x",$0) }.joined()
                }
            }
            if ["AXWindow","AXWebArea","AXTextArea","AXTextField","AXComboBox"].contains(role) {
                var attributeNames: CFArray?
                if AXUIElementCopyAttributeNames(element,&attributeNames) == .success {
                    node["availableAttributes"] = attributeNames as? [String] ?? []
                }
            }
            if ["AXTextArea","AXTextField","AXComboBox"].contains(role) {
                fieldCount += 1
                var writable = DarwinBoolean(false)
                let status = AXUIElementIsAttributeSettable(element,kAXValueAttribute as CFString,&writable)
                node["valueSettable"] = status == .success && writable.boolValue
            }
            let parentIndex = nodes.count; nodes.append(node)
            var rawChildren: CFTypeRef?
            let childStatus = AXUIElementCopyAttributeValue(element,kAXChildrenAttribute as CFString,&rawChildren)
            if childStatus == .success, let children = rawChildren as? [AXUIElement] {
                if depth < 80 { queue.append(contentsOf:children.map { ($0,depth+1,parentIndex) }) }
                else if !children.isEmpty { complete = false }
            } else if childStatus != .attributeUnsupported && childStatus != .noValue {
                childReadFailures += 1; complete = false
            }
        }
        report["nodes"] = nodes; report["nodeCount"] = nodes.count
        report["snapshotComplete"] = complete; report["webAreaCount"] = webAreaCount
        report["maxDepthObserved"] = nodes.compactMap { $0["depth"] as? Int }.max() ?? 0
        report["depthLimit"] = 80; report["nodeLimit"] = 4000; report["timeLimitSeconds"] = 8
        report["documentURLCount"] = documentURLs.count; report["childReadFailures"] = childReadFailures
        report["textFieldCount"] = fieldCount
        // More than one web area is ambiguous in this first experiment.
        report["snapshotURLMatchesTarget"] = AXDiagnosticEvidence.snapshotMatches(urls:documentURLs,webAreaCount:webAreaCount,complete:complete,expectedThreadID:expectedID)
        report["identityVerified"] = false
        report["canSend"] = false
        return report
    }
}

struct DesktopAccessibilityProbeView: View {
    @StateObject private var probe: DesktopAccessibilityProbe
    @Environment(\.dismiss) private var dismiss
    init(model: SessionModel, onWillFill: (() -> Void)? = nil, onFillFailure: (() -> Void)? = nil) {
        let probe = DesktopAccessibilityProbe(root:model.root,session:model.directory,prompt:model.prompt,materials:model.materials)
        probe.onWillFill = onWillFill; probe.onFillFailure = onFillFailure
        _probe = StateObject(wrappedValue:probe)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("发送到 Codex").font(.headline); Spacer(); Button("关闭") { dismiss() }.disabled(probe.busy) }
            ScrollView {
              VStack(alignment:.leading,spacing:12) {
            HStack {
                TextField("搜索对话标题、项目或 ID",text:$probe.search).disabled(probe.busy)
                Button("刷新对话") { probe.refreshConversations() }.disabled(probe.busy)
                if probe.nextCursor != nil { Button("更多") { probe.refreshConversations(more:true) }.disabled(probe.busy) }
            }
            List(probe.filteredConversations,selection:$probe.selectedID) { chat in
                VStack(alignment:.leading,spacing:3) {
                    HStack { Text(chat.name).lineLimit(1); Spacer(); Text(String(chat.id.suffix(8))).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary) }
                    HStack { Text(chat.cwd).lineLimit(1); Spacer(); Text(Date(timeIntervalSince1970:chat.updatedAt),style:.relative) }.font(.system(size:10)).foregroundStyle(.secondary)
                }.tag(chat.id)
            }.frame(height:145).disabled(probe.busy)
            Text("目标：\(probe.targetTitle)")
            Text("选择对话并检查预览后，点击“发送到 Codex”。会自动核对目标；已有草稿时停止，不会覆盖。")
                .font(.system(size:12)).foregroundStyle(.secondary)
            Text(probe.message).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
            if probe.busy { ProgressView() }
            if let text = probe.preparedText {
                Text("本次携带：" + (probe.includedIDs.isEmpty ? "仅正文" : probe.includedIDs.joined(separator:"、")))
                Text("以下是将发送的完整文本。图片和文件以本机副本绝对路径交付，未指定用途的素材不会携带。").font(.system(size:12)).foregroundStyle(.secondary)
                ScrollView { Text(text).font(.system(size:12)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(8) }.frame(height:210).border(.secondary.opacity(0.3))
                Text("发送过程中请勿切换对话。会直接提交当前预览，并核对接收结果。").font(.system(size:11)).foregroundStyle(.secondary)
            }
              }.frame(maxWidth:.infinity,alignment:.leading)
            }.frame(maxHeight:.infinity)
            Divider()
            DisclosureGroup("诊断信息") {
                VStack(alignment:.leading,spacing:8) {
                    Text("目标 ID："+probe.targetID).font(.system(size:11,design:.monospaced)).textSelection(.enabled)
                    HStack {
                        Button("核对目标（不填写）") { probe.openForHumanReview() }.disabled(probe.busy || probe.selectedTarget == nil)
                        if let url = probe.reportURL { Button("查看诊断报告") { NSWorkspace.shared.open(url) } }
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.font(.system(size:11)).disabled(probe.busy)
            HStack {
                if !AXIsProcessTrusted() { Button("允许辅助功能") { probe.permission() }.disabled(probe.busy) }
                if probe.preparedText == nil { Button("重新准备预览") { probe.prepareDraft() }.disabled(probe.busy || probe.sourceSession == nil || probe.sourcePrompt.isEmpty) }
                Spacer()
                Text("点击后直接发送").font(.system(size:11)).foregroundStyle(.secondary)
                Button(probe.busy ? "正在准备…" : "发送到 Codex") { probe.sendReviewedPrompt() }
                    .disabled(!probe.canFillReviewedDraft).buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width:780,height:620).onAppear { probe.refreshConversations(preparePreview:true) }
    }
}
