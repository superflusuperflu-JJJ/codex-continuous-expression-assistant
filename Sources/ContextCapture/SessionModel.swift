import AppKit
import Combine
import ApplicationServices
import PrototypeCore
import CryptoKit

func clockNow() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

@MainActor final class SessionModel: ObservableObject {
    @Published var phase = "ready"
    @Published var status = "准备好后点击开始表达。浏览器需连接扩展；Finder 首次会请求读取权限。"
    @Published var materials: [Material] = []
    @Published var segments: [SpokenSegment] = []
    @Published var anchors: [Anchor] = []
    @Published var gaps: [String] = []
    @Published var prompt = ""
    @Published var liveText = ""
    @Published var voiceEnabled = true
    @Published var browserConnected = false
    @Published var accessibility = AXIsProcessTrusted()
    @Published var refining = false
    @Published var refineNote = ""
    @Published var draining = false
    @Published var autoOrganize = UserDefaults.standard.object(forKey:"autoOrganize") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoOrganize,forKey:"autoOrganize") }
    }
    @Published var evidencePrompt = ""
    @Published var organizationState = "localDraft"
    @Published var reviewChoices: [ReviewChoice] = []
    var organized: OrganizedPrompt?
    var refinementJob: RefinementJob?
    var reviewContext: PromptContext { PromptComposition.context(materials:materials,segments:segments,anchors:anchors,gaps:gaps) }
    var visibleMaterials: [Material] {
        guard phase == "reviewing" else { return materials }
        let ids = Set(reviewContext.materials.map(\.id))
        return materials.filter { ids.contains($0.id) }
    }
    var showReview: (() -> Void)?
    var sessionID = ""
    var directory: URL?
    let root: URL
    let desktopDelivery: DesktopAccessibilityProbe
    let projectRoot: URL
    var active: Bool { phase == "capturing" }
    private var speech = SpeechCapture()
    private var bridge: LocalBridge?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var pollCount = 0
    private var finderBusy = false
    private var finderWindow = SelectionObservationWindow()
    private var transcriptMode = "live"
    private var pending = 0
    private var fingerprint = ""
    private var pageObservation = ""
    private var lastPID: pid_t = 0
    private var lastBrowserPing = 0.0
    private var finalIDs = Set<String>()
    var originalPrompt = ""
    var cutoff: Double?
    private var browserBarrier = false
    private var startup: Task<Void, Never>?
    private var axBusy = false
    private var autoSave: Task<Void, Never>?

    init(rootOverride: URL? = nil, startServices: Bool = true) {
        root = rootOverride ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ContextCapturePrototype")
        desktopDelivery = DesktopAccessibilityProbe(root:root)
        projectRoot = ApplicationRuntime.current.resourceRoot
        guard startServices else { return }
        do {
            try FileManager.default.createDirectory(at:root, withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
            let bridge = LocalBridge { [weak self] object, reply in self?.browserMessage(object, reply:reply) }
            try bridge.start(socketURL:root.appendingPathComponent("bridge.sock")) { [weak self] error in Task { @MainActor in self?.gap("浏览器连接失败：" + error) } }
            self.bridge = bridge
        } catch { gap("本地连接启动失败：" + error.localizedDescription) }
        timer = Timer.scheduledTimer(withTimeInterval:0.06, repeats:true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification, object:nil, queue:.main) { [weak self] _ in
            Task { @MainActor in if self?.active == true { self?.gap("系统从睡眠恢复，本段时间对齐需核对；建议结束并重新开始。") } }
        }
    }

    func askAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibility = AXIsProcessTrustedWithOptions(options)
        if !accessibility { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    }

    func gap(_ text: String) {
        if !gaps.contains(text) { gaps.append(text); journal(["type":"gap","time":clockNow(),"message":text]) }
    }
    func journal(_ event: [String: Any]) {
        guard let directory, let data = try? JSONSerialization.data(withJSONObject:event,options:[.sortedKeys]) else { return }
        let url = directory.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath:url.path) { FileManager.default.createFile(atPath:url.path,contents:nil) }
        do { let file = try FileHandle(forWritingTo:url); try file.seekToEnd(); try file.write(contentsOf:data + Data([10])); try file.close() }
        catch { status = "会话证据保存失败：" + error.localizedDescription }
    }

    func receiveSpeech(_ segment: SpokenSegment, final: Bool) {
        var segment = segment
        // Final results can shift the same audio boundary by tens of microseconds.
        // Replace only a matching time boundary; repeated words at later times remain distinct.
        if let index = segments.firstIndex(where: { $0.id == segment.id || abs($0.start - segment.start) < 0.001 }) {
            segment.id = segments[index].id
            segments[index] = segment
        } else { segments.append(segment) }
        if final { finalIDs.insert(segment.id) }
        liveText = segments.sorted(by: {$0.start < $1.start}).map(\.text).joined()
        journal(["type":"speech","id":segment.id,"time":segment.start,"end":segment.end,"final":final,"text":segment.text])
    }

    func applyFinalTranscript(_ review: SpeechReview) {
        segments = review.segments
        finalIDs = Set(segments.map(\.id)); transcriptMode = "fullRecording"
        liveText = segments.map(\.text).joined()
        journal(["type": "speechReview", "mode": transcriptMode, "segments": segments.count, "time": clockNow()])
        if let directory {
            do { try JSONEncoder().encode(review.spans).write(to: directory.appendingPathComponent("audio-timeline.json"), options: .atomic) }
            catch { gap("音频时间映射保存失败：" + error.localizedDescription) }
        }
    }

    func start() {
        guard (phase == "ready" || phase == "reviewing"), !draining, !refining else { return }
        if directory != nil { save() }
        organized = nil; reviewChoices = []; evidencePrompt = ""; organizationState = "localDraft"; refineNote = ""
        phase = "preparing"; status = "正在准备本次表达…"
        materials = []; segments = []; anchors = []; gaps = []; prompt = ""; liveText = ""; fingerprint = ""; finalIDs = []
        pageObservation = ""
        sessionID = UUID().uuidString; cutoff = nil; browserBarrier = false; transcriptMode = "live"; finderWindow.reset()
        directory = root.appendingPathComponent("Sessions/" + sessionID)
        do { try FileManager.default.createDirectory(at:directory!.appendingPathComponent("assets"),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]) }
        catch { phase = "ready"; status = error.localizedDescription; return }
        let expectedSession = sessionID
        startup = Task {
            do {
                if voiceEnabled {
                    try await speech.start(audioURL:directory!.appendingPathComponent("audio.caf"), status:{ [weak self] text in
                        Task { @MainActor in guard self?.sessionID == expectedSession else { return }; self?.status = text }
                    }, result:{ [weak self] segment, final in
                        Task { @MainActor in
                            guard let self, self.sessionID == expectedSession else { return }
                            self.receiveSpeech(segment, final: final)
                        }
                    }, failure:{ [weak self] error in Task { @MainActor in guard self?.sessionID == expectedSession else { return }; self?.gap(error) } })
                }
                guard self.sessionID == expectedSession else { await speech.cancel(); return }
                phase = "capturing"; status = voiceEnabled ? "正在倾听 · 选中素材后自然说要求" : "仅采集素材 · 本段没有语音"
                if !voiceEnabled { gap("本段未开启语音，请在最终稿补充任务要求。") }
                journal(["type":"start","time":clockNow(),"session":sessionID])
            } catch {
                guard self.sessionID == expectedSession else { return }
                await speech.cancel(); phase = "ready"; status = error.localizedDescription; gap(error.localizedDescription)
            }
        }
    }

    func finish() {
        guard active else { return }
        let cutoff = clockNow(); self.cutoff = cutoff; browserBarrier = !browserConnected
        phase = "finalizing"; status = "正在收齐语音与素材…"; closeAnchor(at:cutoff)
        let session = sessionID
        journal(["type":"finish","time":cutoff])
        draining = true
        Task {
            if voiceEnabled {
                status = "正在完整复核本次语音…"
                do {
                    let review = try await speech.stop()
                    if sessionID == session, phase == "finalizing" { applyFinalTranscript(review) }
                } catch { gap("整段语音复核未完成，保留实时结果：" + error.localizedDescription) }
            }
            draining = false
            guard sessionID == session, phase == "finalizing" else { return }
            let deadline = clockNow() + 6
            while (pending > 0 || !browserBarrier) && clockNow() < deadline && sessionID == session { try? await Task.sleep(for:.milliseconds(50)) }
            guard sessionID == session else { return }
            if pending > 0 { gap("部分素材仍在处理，本稿不完整；稍后请重新整理。") }
            if !browserBarrier { gap("浏览器尚未确认采集结束，最后的选择可能未收齐，请核对。") }
            if !Set(segments.map(\.id)).isSubset(of:finalIDs), voiceEnabled { gap("部分语音仍为临时识别结果，请核对。") }
            for index in segments.indices where segments[index].end > cutoff {
                if segments[index].hasSpeech(after: cutoff) { gap("有一段语音跨越结束时刻，请核对句尾。") }
                segments[index].end = cutoff
            }
            prepareReview()
            phase = "reviewing"; status = "语音与素材已收齐，正在准备请求正文。"
            save(); showReview?()
            if autoOrganize && !segments.isEmpty { refine() }
            else { status = "本地草稿已生成，尚未完成语义合并；可以点击整理 Prompt。" }
        }
    }

    func cancelPreparation() {
        guard phase == "preparing" else { return }
        startup?.cancel(); sessionID = UUID().uuidString
        Task { await speech.cancel(); phase = "ready"; status = "准备已取消。可关闭语音先试素材采集。" }
    }

    func showPartialReview() {
        guard phase == "finalizing" else { return }
        gap("用户选择先查看当前内容，语音或素材可能尚未收齐；这是不完整草稿。")
        prepareReview()
        phase = "reviewing"; save(); showReview?()
    }

    func closeAnchor(at time: Double, source: String? = nil, uncertainty: Double = 0) {
        for index in anchors.indices where anchors[index].start <= time && (source == nil || anchors[index].source == source) {
            if anchors[index].end == nil || anchors[index].end! > time { anchors[index].end = time; anchors[index].endUncertainty = uncertainty }
        }
        fingerprint = ""
    }

    func record(materials items: [Material], at time: Double, source: String, uncertainty: Double = 0.03,
                selectionID: String? = nil, selectionComplete: Bool? = nil, selectionStart: Double? = nil) {
        let key = source + "|" + (selectionID ?? "") + "|" + String(selectionComplete ?? false) + "|" + items.map { $0.kind + ":" + $0.content + ":" + ($0.evidenceDigest ?? "") }.joined(separator:"|")
        guard key != fingerprint else { return }
        var ids: [String] = []
        for item in items {
            if let old = materials.first(where:{$0.kind == item.kind && $0.source == item.source && $0.content == item.content && $0.evidenceDigest == item.evidenceDigest}) { ids.append(old.id) }
            else { var copy = item; copy.id = "M\(materials.count + 1)"; materials.append(copy); ids.append(copy.id) }
        }
        fingerprint = key
        if !ids.isEmpty {
            anchors.append(Anchor(ids,start:time,end:phase == "finalizing" ? cutoff : nil,source:source,uncertainty:uncertainty,
                selectionID:selectionID,selectionComplete:selectionComplete,selectionStart:selectionStart))
            anchors = CaptureOrdering.sortedIntervals(anchors)
        }
        journal(["type":"anchor","time":time,"source":source,"materials":ids,"uncertainty":uncertainty])
    }

    private func poll() {
        pollCount += 1
        accessibility = AXIsProcessTrusted()
        browserConnected = clockNow() - lastBrowserPing < 5
        guard active, let front = NSWorkspace.shared.frontmostApplication else { return }
        if front.processIdentifier != lastPID { closeAnchor(at:clockNow(),uncertainty:0.06); finderWindow.reset(); lastPID = front.processIdentifier }
        guard front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        if front.bundleIdentifier == "com.apple.finder" { pollFinder(pid:front.processIdentifier); return }
        guard accessibility, front.bundleIdentifier != "com.google.Chrome" || !browserConnected else { return }
        let pid = front.processIdentifier
        let at = clockNow(); let source = front.localizedName ?? "应用"
        guard !axBusy else { return }; axBusy = true; pending += 1
        let session = sessionID
        DispatchQueue.global(qos:.userInitiated).async {
            let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app,0.08)
            var focused: CFTypeRef?, selected: CFTypeRef?
            var text: String?
            if AXUIElementCopyAttributeValue(app,kAXFocusedUIElementAttribute as CFString,&focused) == .success, let focused {
                let element = focused as! AXUIElement; AXUIElementSetMessagingTimeout(element,0.08)
                if AXUIElementCopyAttributeValue(element,kAXSelectedTextAttribute as CFString,&selected) == .success { text = selected as? String }
            }
            Task { @MainActor in
                self.axBusy = false; self.pending -= 1
                guard self.sessionID == session, CaptureOrdering.accepts(time:at,cutoff:self.cutoff,collecting:self.active,finalizing:self.phase == "finalizing") else { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { self.closeAnchor(at:at); return }
                self.applyAXSelection(text,at:at,source:source)
            }
        }
    }

    func applyAXSelection(_ text: String?, at: Double, source: String) {
        guard let text else { closeAnchor(at:at); return }
        if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { closeAnchor(at:at); return }
        if text.count <= 20000 { record(materials:[Material(id:"",kind:"文字",label:String(text.prefix(80)),source:source,content:text)],at:at,source:source,uncertainty:0.3) }
        else { closeAnchor(at:at); gap("选中文字过长，未纳入；请缩小选区。") }
    }

    private func pollFinder(pid: pid_t) {
        guard !finderBusy else { return }
        finderBusy = true; pending += 1
        let at = clockNow(), session = sessionID
        DispatchQueue.global(qos:.userInitiated).async {
            let script = NSAppleScript(source:"""
                with timeout of 1 seconds
                    tell application "Finder"
                        set itemsList to selection
                        set resultList to {}
                        repeat with itemRef in itemsList
                            set end of resultList to URL of itemRef
                        end repeat
                        return resultList
                    end tell
                end timeout
                """)
            var error: NSDictionary?
            let descriptor = script?.executeAndReturnError(&error)
            var paths: [String] = []
            if let descriptor, descriptor.numberOfItems > 0 {
                for index in 1...descriptor.numberOfItems { if let value = descriptor.atIndex(index)?.stringValue, let url = URL(string:value), url.isFileURL { paths.append(url.path) } }
            }
            let errorText = error?[NSAppleScript.errorMessage] as? String
            let completedAt = clockNow()
            Task { @MainActor in
                self.pending -= 1; self.finderBusy = false
                guard self.sessionID == session, CaptureOrdering.accepts(time:at,cutoff:self.cutoff,collecting:self.active,finalizing:self.phase == "finalizing") else { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid || self.phase == "finalizing" else {
                    self.closeAnchor(at:at); self.gap("Finder 读取选区时切换了应用，该次选择未作确定关联。"); return
                }
                if let errorText { self.finderWindow.reset(); self.closeAnchor(at:at); self.gap("Finder 文件读取失败：\(errorText)。可把文件拖入原型窗口替代。"); return }
                let observation = self.finderWindow.observe(start:at,end:completedAt)
                if paths.isEmpty { self.closeAnchor(at:observation.time,uncertainty:observation.uncertainty); return }
                let items = paths.sorted().map { Material(id:"",kind:"文件",label:URL(fileURLWithPath:$0).lastPathComponent,source:"Finder",content:$0,availability:"referenceOnly") }
                self.record(materials:items,at:observation.time,source:"Finder",uncertainty:observation.uncertainty)
                self.journal(["type":"finderRead","start":at,"end":completedAt,"boundary":observation.time,"uncertainty":observation.uncertainty])
                self.copyFiles(paths:paths, session:session)
            }
        }
    }

    func copyFiles(paths: [String], session: String) {
        guard let directory else { return }
        for path in paths {
            guard let index = materials.firstIndex(where:{$0.content == path}), materials[index].localPath == nil,
                  materials[index].availability != "copying" else { continue }
            materials[index].availability = "copying"; pending += 1
            let id = materials[index].id
            DispatchQueue.global(qos:.utility).async {
                let original = URL(fileURLWithPath:path)
                let target = directory.appendingPathComponent("assets/\(id)-\(original.lastPathComponent)")
                var outcome: String?
                do {
                    let before = try original.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey,.contentModificationDateKey])
                    guard before.isRegularFile == true else { throw NSError(domain:"File",code:1,userInfo:[NSLocalizedDescriptionKey:"文件夹暂不复制"]) }
                    guard (before.fileSize ?? 0) <= 50*1024*1024 else { throw NSError(domain:"File",code:2,userInfo:[NSLocalizedDescriptionKey:"文件大于 50MB，当前仅保留路径"]) }
                    try FileManager.default.copyItem(at:original,to:target)
                    let after = try original.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
                    guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
                        try? FileManager.default.removeItem(at:target)
                        throw NSError(domain:"File",code:3,userInfo:[NSLocalizedDescriptionKey:"文件在读取中变化，请重新选择"])
                    }
                } catch { outcome = error.localizedDescription }
                Task { @MainActor in
                    self.pending -= 1
                    guard self.sessionID == session, let index = self.materials.firstIndex(where:{$0.id == id}) else { return }
                    if let outcome { self.materials[index].availability = "referenceOnly"; self.gap("\(original.lastPathComponent)：\(outcome)") }
                    else { self.materials[index].availability = "original"; self.materials[index].localPath = target.path }
                }
            }
        }
    }

    func receiveFiles(_ urls: [URL]) {
        guard active else { status = "请先开始表达，再拖入文件。"; return }
        record(materials:urls.map{Material(id:"",kind:"文件",label:$0.lastPathComponent,source:"拖入",content:$0.path,availability:"referenceOnly")},at:clockNow(),source:"拖入",uncertainty:0.03)
        copyFiles(paths:urls.map(\.path),session:sessionID)
    }

    func browserMessage(_ object: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        lastBrowserPing = clockNow(); browserConnected = true
        if object["type"] as? String == "hello", object["diagnostic"] as? Bool == true {
            reply(["phase":phase,"pollCount":pollCount,"finderBusy":finderBusy,"pending":pending,
                   "frontmost":NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"]); return
        }
        if object["type"] as? String == "hello" {
            if active, let page = object["page"] as? [String:Any], let source = page["source"] as? String,
               let url = URL(string:source), ["http","https","file"].contains(url.scheme ?? ""),
               let data = try? JSONSerialization.data(withJSONObject:page,options:[.sortedKeys]) {
                let key = String(decoding:data,as:UTF8.self)
                if key != pageObservation { pageObservation = key; journal(["type":"pageCollector","time":clockNow(),"page":page]) }
            }
            reply(["active":active,"phase":phase,"cutoff":cutoff ?? 0,"session":sessionID,"monotonic":clockNow()]); return
        }
        if object["type"] as? String == "barrier", object["session"] as? String == sessionID { browserBarrier = true; reply(["ok":true]); return }
        guard object["session"] as? String == sessionID,
              let kind = object["kind"] as? String, let at = object["occurredAt"] as? Double,
              CaptureOrdering.accepts(time:at,cutoff:cutoff,collecting:active,finalizing:phase == "finalizing"),
              abs(clockNow()-at) < 10 else { reply(["ok":false]); return }
        guard let source = object["source"] as? String,
              let sourceURL = URL(string:source), ["http","https","file"].contains(sourceURL.scheme ?? ""),
              object["tabID"] != nil, let documentID = object["documentID"] as? String, !documentID.isEmpty else {
            reply(["ok":false,"error":"缺少有效页面身份"]); return
        }
        let sourceIdentity = source + "|" + String(describing:object["tabID"] ?? "") + "|" + String(describing:object["documentID"] ?? "")
        if kind == "clear" { closeAnchor(at:at,source:sourceIdentity); reply(["ok":true]); return }
        let content = object["content"] as? String ?? ""
        guard content.utf8.count <= 100000 else { reply(["ok":false]); return }
        let selectedText = object["selectedText"] as? String
        var item = Material(id:"",kind:selectedText != nil ? "文字" : kind == "image" ? "图片" : kind == "link" ? "链接" : "文字",
            label:String((object["label"] as? String ?? content).prefix(160)),source:source,content:selectedText ?? content,
            availability:kind == "image" ? "referenceOnly" : "original")
        if let screenshot = object["screenshot"] as? String, let comma = screenshot.firstIndex(of:","),
           let data = Data(base64Encoded:String(screenshot[screenshot.index(after:comma)...])), data.count <= 8*1024*1024, let directory {
            let target = directory.appendingPathComponent("assets/image-\(UUID().uuidString).jpg")
            do { try data.write(to:target,options:.atomic); item.localPath = target.path; item.availability = "excerpt"; item.evidenceDigest = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
            catch { gap("网页图片截图保存失败：" + error.localizedDescription) }
        }
        if kind == "image", item.localPath == nil { gap(object["imageNote"] as? String ?? "所选图片仅保留来源，尚无图片原件或截图。") }
        var captured = [item]
        if let links = object["links"] as? [[String:String]] {
            captured += links.compactMap { link in
                guard let url = link["url"] else { return nil }
                return Material(id:"",kind:"链接",label:link["label"] ?? url,source:source,content:url)
            }
            if links.count > 1 { gap("有一段选区包含多个链接，请在最终稿核对具体目标。") }
        }
        record(materials:captured,at:at,source:sourceIdentity,uncertainty:max(0.03,object["uncertainty"] as? Double ?? 0.3),
            selectionID:object["selectionID"] as? String,selectionComplete:object["selectionComplete"] as? Bool,
            selectionStart:object["selectionStart"] as? Double)
        journal(["type":"browserEvidence","time":at,"source":source,"documentID":object["documentID"] ?? "","rect":object["rect"] ?? [:],"viewport":object["viewport"] ?? [:]])
        reply(["ok":true,"imageCaptured":kind == "image" && item.localPath != nil])
    }

    func prepareReview() {
        if materials.isEmpty && segments.contains(where: { Association.bindings(for:$0,anchors:anchors).contains(where: { $0.materialIDs.isEmpty }) }) {
            gap("语音中提到了素材，但没有收到任何素材。如果你选择了网页内容，请检查当前网页采集连接后重试。")
        }
        evidencePrompt = PromptRenderer.render(materials:materials,segments:segments,anchors:anchors,gaps:gaps)
        prompt = PromptComposition.localDraft(reviewContext)
        originalPrompt = prompt; organized = nil; reviewChoices = []; organizationState = "localDraft"
    }

    func refinementContext() -> PromptContext {
        let context = reviewContext
        guard prompt != originalPrompt || organizationState == "organized" else { return context }
        // An edited draft replaces the original requirements; deleted requests cannot return.
        let ids = PromptComposition.references(in:prompt)
        return PromptContext(speech:[PromptSpeech(id:"edited-draft",text:prompt,bindings:[],selectedMaterialIDs:Array(ids))],
            materials:context.materials.filter { ids.contains($0.id) },gaps:[])
    }

    func acceptRefinement(_ result: OrganizedPrompt, context: PromptContext, snapshot: String) throws {
        try PromptComposition.validate(result,for:context)
        let text = PromptComposition.render(result,context:context)
        guard prompt == snapshot else {
            if let directory { try text.write(to:directory.appendingPathComponent("prompt-suggestion.md"),atomically:true,encoding:.utf8) }
            refineNote = "你已编辑正文；建议稿另存，未覆盖。"; return
        }
        organized = result; reviewChoices = (result.resolutions ?? []).map(ReviewChoice.init); organizationState = "organized"
        prompt = text; originalPrompt = text; save()
        refineNote = "已合并表达、保留来源，请核对正文。"; status = "Prompt 已整理完成，可编辑或复制。"
    }

    func loadLatestSession() {
        guard !active, !refining, !draining, phase != "preparing", phase != "finalizing" else { return }
        do {
            let folders = try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("Sessions"),includingPropertiesForKeys:[.contentModificationDateKey])
                .sorted { ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            guard let folder = folders.first(where:{ FileManager.default.fileExists(atPath:$0.appendingPathComponent("transcript.json").path) }) else { status = "没有可打开的表达记录。"; return }
            let decoder = JSONDecoder()
            let items = try decoder.decode([Material].self,from:Data(contentsOf:folder.appendingPathComponent("materials.json")))
            let words = try decoder.decode([SpokenSegment].self,from:Data(contentsOf:folder.appendingPathComponent("transcript.json")))
            let points = try decoder.decode([Anchor].self,from:Data(contentsOf:folder.appendingPathComponent("anchors.json")))
            let manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("manifest.json"))) as? [String:Any]
            if directory != nil { save() }
            directory = folder; sessionID = folder.lastPathComponent; materials = items; segments = words; anchors = points
            gaps = manifest?["gaps"] as? [String] ?? []; transcriptMode = manifest?["transcriptMode"] as? String ?? "live"
            prepareReview()
            if let state = manifest?["structuredStatus"] as? String, state != "evidenceDraft", let saved = try? String(contentsOf:folder.appendingPathComponent("prompt.md"),encoding:.utf8) {
                prompt = saved; organizationState = state == "organized" ? "organized" : "localDraft"
                if state != "staleAfterUserEdit" { originalPrompt = saved }
            }
            if let data = try? Data(contentsOf:folder.appendingPathComponent("review-choices.json")),
               let choices = try? decoder.decode([ReviewChoice].self,from:data) { reviewChoices = choices }
            phase = "reviewing"; refineNote = "已打开上次表达；点击整理 Prompt 可重新整理。"; status = "已打开上次表达，尚未发起网络整理。"
        } catch { status = "打开表达记录失败：" + error.localizedDescription }
    }

    func save() {
        guard let directory else { return }
        do {
            try prompt.write(to:directory.appendingPathComponent("prompt.md"),atomically:true,encoding:.utf8)
            if !evidencePrompt.isEmpty { try evidencePrompt.write(to:directory.appendingPathComponent("evidence.md"),atomically:true,encoding:.utf8) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(reviewChoices).write(to:directory.appendingPathComponent("review-choices.json"),options:.atomic)
            if let organized { try encoder.encode(organized).write(to:directory.appendingPathComponent("organized-request.json"),options:.atomic) }
            try encoder.encode(materials).write(to:directory.appendingPathComponent("materials.json"),options:.atomic)
            try encoder.encode(segments).write(to:directory.appendingPathComponent("transcript.json"),options:.atomic)
            try encoder.encode(anchors).write(to:directory.appendingPathComponent("anchors.json"),options:.atomic)
            let manifest: [String:Any] = ["schemaVersion":1,"session":sessionID,"canonicalText":prompt,"transcriptMode":transcriptMode,
                "canonicalTextHash":SHA256.hash(data:Data(prompt.utf8)).map{String(format:"%02x",$0)}.joined(),
                "structuredStatus":prompt == originalPrompt ? organizationState : "staleAfterUserEdit", "gaps":gaps,
                "activeRequirements":NSNull()]
            try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("manifest.json"),options:.atomic)
        } catch { status = "保存失败：" + error.localizedDescription }
    }

    func scheduleSave() {
        guard phase == "reviewing" else { return }
        autoSave?.cancel()
        let session = sessionID
        autoSave = Task {
            do { try await Task.sleep(for:.milliseconds(500)) } catch { return }
            guard sessionID == session, phase == "reviewing" else { return }; save()
        }
    }

    func copyPrompt() { save(); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(prompt,forType:.string); status = "已复制正文；素材副本在会话文件夹中。" }
    func reveal() { save(); if let directory { NSWorkspace.shared.open(directory) } }
    func export() {
        save(); guard let directory else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "导出到此处"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do { let output = target.appendingPathComponent("表达记录-" + String(sessionID.prefix(8))); try FileManager.default.copyItem(at:directory,to:output); NSWorkspace.shared.open(output); status = "已导出本次 Prompt、素材和证据。" }
        catch { status = "导出失败：" + error.localizedDescription }
    }
}
