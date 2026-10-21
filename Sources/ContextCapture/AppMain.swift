import AppKit
import SwiftUI
import Carbon
import Speech
import AVFoundation

@main struct PrototypeApplication {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of:"--composition-check"), CommandLine.arguments.count > index+2 {
            let sourceIndex = CommandLine.arguments.firstIndex(of:"--source-session")
            let source = sourceIndex.flatMap { $0+1 < CommandLine.arguments.count ? URL(fileURLWithPath:CommandLine.arguments[$0+1]) : nil }
            exit(Int32(SessionModel.compositionSample(executable:CommandLine.arguments[index+1],output:URL(fileURLWithPath:CommandLine.arguments[index+2]),source:source)))
        }
        if CommandLine.arguments.contains("--self-test") { exit(Int32(SessionModel.integrationChecks())) }
        if CommandLine.arguments.contains("--diagnose") {
            Task {
                let supported = await SpeechTranscriber.supportedLocales
                let installed = await SpeechTranscriber.installedLocales
                let result: [String:Any] = ["speechAvailable":SpeechTranscriber.isAvailable,
                    "zhCN":await SpeechTranscriber.supportedLocale(equivalentTo:Locale(identifier:"zh-CN"))?.identifier ?? "unsupported",
                    "supportedLocales":supported.map(\.identifier),"installedLocales":installed.map(\.identifier),
                    "microphoneStatus":AVCaptureDevice.authorizationStatus(for:.audio).rawValue]
                if let data = try? JSONSerialization.data(withJSONObject:result,options:.sortedKeys), let text = String(data:data,encoding:.utf8) { print(text) }
                exit(0)
            }
            RunLoop.main.run(); return
        }
        if let argument = CommandLine.arguments.firstIndex(of:"--transcribe-file"), CommandLine.arguments.count > argument+1 {
            let path = CommandLine.arguments[argument+1]
            Task {
                do {
                    let segments = try await SpeechCapture.transcribeFile(URL(fileURLWithPath:path))
                    let content = segments.map(\.text).joined()
                    let timedRuns = segments.reduce(0) { $0 + $1.words.count }
                    print("TRANSCRIPT: \(content)\nTIMED_RUNS: \(timedRuns)")
                    if CommandLine.arguments.contains("--timed-json") {
                        print(String(data: try JSONEncoder().encode(segments), encoding: .utf8)!)
                    }
                    exit(content.isEmpty || timedRuns == 0 ? 1 : 0)
                } catch { print("SPEECH_FAILED: \(error.localizedDescription)"); exit(1) }
            }
            RunLoop.main.run(); return
        }
        let app = NSApplication.shared
        let delegate = PrototypeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor final class PrototypeDelegate: NSObject, NSApplicationDelegate {
    let model = SessionModel()
    var window: NSWindow!
    let edgeSettings = EdgePanelSettings()
    var edgePanel: RightEdgePanel?
    var settingsWindow: NSWindow?
    var statusItem: NSStatusItem!
    var hotKey: EventHotKeyRef?
    var handler: EventHandlerRef?
    var poll: Timer?
    var fixtureServer: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let python = Bundle.main.object(forInfoDictionaryKey:"PythonExecutable") as? String {
            let server = Process(); server.executableURL = URL(fileURLWithPath:python)
            server.arguments = ["-m","http.server","9876","--bind","127.0.0.1","--directory",model.projectRoot.appendingPathComponent("Fixtures").path]
            server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
            do { try server.run(); fixtureServer = server } catch { model.gap("试用页面服务未启动；仍可使用普通网页。") }
        }
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1060,height:720),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "Codex连续表达助手"; window.minSize = NSSize(width:850,height:560)
        window.contentView = NSHostingView(rootView:PrototypeView(model:model,settings:edgeSettings))
        window.center()
        edgePanel = RightEdgePanel(model:model,settings:edgeSettings)
        edgeSettings.changed = { [weak self] in self?.applyEdgeMode() }
        edgeSettings.openSettings = { [weak self] in self?.showSettings() }
        if edgeSettings.enabled { edgePanel?.setEnabled(true) } else { show() }
        model.showReview = { [weak self] in self?.show() }
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle:"显示 Codex连续表达助手",action:#selector(show),keyEquivalent:"0").target = self
        appMenu.addItem(withTitle:"设置…",action:#selector(showSettings),keyEquivalent:",").target = self
        appMenu.addItem(withTitle:"退出",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title:"编辑"); editItem.submenu = editMenu
        for (title, selector, key) in [("撤销","undo:","z"),("剪切","cut:","x"),("复制","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")] {
            editMenu.addItem(withTitle:title,action:NSSelectorFromString(selector),keyEquivalent:key)
        }
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(withTitle:"开始／结束表达  ⌘⇧↩",action:#selector(toggle),keyEquivalent:"").target = self
        menu.addItem(withTitle:"查看 Prompt",action:#selector(show),keyEquivalent:"").target = self
        menu.addItem(withTitle:"设置…",action:#selector(showSettings),keyEquivalent:"").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle:"退出",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"")
        statusItem.menu = menu
        poll = Timer.scheduledTimer(withTimeInterval:0.4,repeats:true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.statusItem.button?.title = self.model.active ? "● 倾听中" : self.model.phase == "finalizing" ? "◌ 整理中" : "◉ 连续表达"
            }
        }
        var type = EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<PrototypeDelegate>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor in delegate.toggle() }; return noErr
        },1,&type,pointer,&handler)
        let error = RegisterEventHotKey(36,UInt32(cmdKey|shiftKey),EventHotKeyID(signature:0x43545052,id:1),GetApplicationEventTarget(),0,&hotKey)
        if error != noErr { model.gap("全局快捷键 ⌘⇧Return 注册失败，先使用菜单栏开始／结束。") }
    }
    func applyEdgeMode() {
        if edgeSettings.enabled { window.orderOut(nil); edgePanel?.setEnabled(true); edgePanel?.reveal() }
        else { edgePanel?.setEnabled(false); show() }
    }
    @objc func showSettings() {
        if settingsWindow == nil {
            let preferences = NSWindow(contentRect:NSRect(x:0,y:0,width:430,height:250),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            preferences.title = "Codex连续表达助手设置"; preferences.isReleasedWhenClosed = false
            preferences.contentView = NSHostingView(rootView:EdgePanelSettingsView(settings:edgeSettings))
            preferences.center(); settingsWindow = preferences
        }
        NSApp.activate(ignoringOtherApps:true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func show() {
        if edgeSettings.enabled { edgePanel?.reveal(activate:true) }
        else { NSApp.activate(ignoringOtherApps:true); window.makeKeyAndOrderFront(nil) }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if edgeSettings.enabled, settingsWindow?.isVisible != true { edgePanel?.reveal() }
    }
    @objc func toggle() {
        if model.active { model.finish() }
        else if model.phase == "ready" || model.phase == "reviewing" { model.start() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        edgePanel?.stop(); model.cancelRefinement(); model.save(); if let hotKey { UnregisterEventHotKey(hotKey) }
        if fixtureServer?.isRunning == true { fixtureServer?.terminate() }
    }
}

struct PrototypeView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var settings: EdgePanelSettings
    @State private var help = false
    @State private var evidence = false
    var body: some View {
      GeometryReader { geometry in
       ScrollView {
        VStack(alignment:.leading,spacing:18) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:5) {
                    Text("把现场，变成清楚的请求").font(.system(size:25,weight:.semibold))
                    Text("选中素材，自然说。结束后一起核对。  ⌘⇧Return 开始／结束")
                        .font(.system(size:13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("设置") { settings.openSettings?() }
                Button("使用说明") { help.toggle() }
            }
            HStack(spacing:16) {
                Label(model.accessibility ? "辅助功能已允许" : "辅助功能（其他应用文字，可选）",systemImage:model.accessibility ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(model.accessibility ? Color.green : Color.orange)
                if !model.accessibility { Button("去允许") { model.askAccessibility() } }
                Divider().frame(height:18)
                Label(model.browserConnected ? "浏览器已连接" : "浏览器尚未连接",systemImage:"globe")
                if !model.browserConnected {
                    Button("扩展文件夹") { NSWorkspace.shared.open(model.root.appendingPathComponent("BrowserExtension")) }
                    Button("扩展管理") { openChrome("chrome://extensions") }
                }
                Spacer()
            }.font(.system(size:12))
            if help {
                VStack(alignment:.leading,spacing:6) {
                    Text("首次：在 Chrome 扩展管理中打开开发者模式，点击“加载已解压的扩展程序”，选择刚打开的 BrowserExtension 文件夹。").fontWeight(.medium)
                    Text("首次扩展更新需要一次性允许网页截图。开始表达后：网页文字直接选择；图片和链接按住 Option 点击（也可右键“纳入本次表达”），无需再点扩展图标；Finder 文件直接选择。结束后在右侧编辑并复制 Prompt。")
                    Text("语音使用本地中文模型，首次可能下载；实时文字用于预览，结束后完整复核并显示 Prompt。录音、素材副本和转写只保存在本机；“结束并整理 Prompt”会把本次转写、选中文字和素材说明交给你现有 Codex 登录进行整理，不执行所述任务。")
                    Text("这是验证原型：跨历史指代和复杂更正会标为待确认；网页图片目前保存页面截图与图片来源，不冒称图片原件。")
                }.font(.system(size:12)).padding(12).background(Color.green.opacity(0.06),in:RoundedRectangle(cornerRadius:10))
            }
            HStack(spacing:12) {
                Circle().fill(model.active ? Color.green : Color.gray).frame(width:9,height:9)
                Text(model.status).font(.system(size:13)).lineLimit(2)
                Spacer()
                Toggle("语音",isOn:$model.voiceEnabled).disabled(model.phase != "ready" && model.phase != "reviewing")
                if model.phase == "preparing" { Button("取消准备") { model.cancelPreparation() } }
                if model.phase == "finalizing" { Button("先查看当前内容") { model.showPartialReview() } }
                if model.active {
                    Button(model.autoOrganize ? "结束并整理 Prompt" : "结束并查看草稿") { model.finish() }.buttonStyle(.borderedProminent)
                } else {
                    Button(model.phase == "preparing" ? "正在准备…" : model.phase == "finalizing" ? "正在收齐…" : "开始表达") { model.start() }
                        .buttonStyle(.borderedProminent).disabled(model.phase == "preparing" || model.phase == "finalizing" || model.refining || model.draining)
                }
            }
            HStack {
                Toggle("结束后自动整理 Prompt",isOn:$model.autoOrganize).toggleStyle(.checkbox)
                    .disabled(model.phase != "ready" && model.phase != "reviewing")
                Text("使用现有 Codex 登录和网络整理转写、选中文字与素材说明；图片、文件内容留在本机。")
                    .font(.system(size:11)).foregroundStyle(.secondary)
            }
            CodexTargetPicker(probe:model.desktopDelivery)
            HSplitView {
                VStack(alignment:.leading,spacing:10) {
                    Text("本次素材 · \(model.visibleMaterials.count)").font(.headline)
                    ScrollView {
                        LazyVStack(alignment:.leading,spacing:10) {
                            if model.visibleMaterials.isEmpty { Text("开始后选中的素材会出现在这里。\n\n也可以把本地文件拖到这里。").foregroundStyle(.secondary).font(.system(size:13)).padding(.top,20) }
                            ForEach(model.visibleMaterials) { item in
                                VStack(alignment:.leading,spacing:5) {
                                    Text("\(item.id)  \(item.kind)").font(.system(size:11,weight:.semibold)).foregroundStyle(.green)
                                    Text(item.label).font(.system(size:13)).lineLimit(3)
                                    Text(item.source).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1)
                                    if let path = item.localPath, ["jpg","png"].contains(URL(fileURLWithPath:path).pathExtension.lowercased()), let image = NSImage(contentsOfFile:path) {
                                        Image(nsImage:image).resizable().scaledToFit().frame(maxHeight:100)
                                    }
                                    if item.availability == "referenceOnly" { Text("仅来源，尚无原件").font(.system(size:10)).foregroundStyle(.orange) }
                                }.frame(maxWidth:.infinity,alignment:.leading).padding(11).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:9))
                            }
                        }
                    }
                }.padding(.trailing,12).frame(minWidth:220,idealWidth:275,maxWidth:340)
                    .onDrop(of:["public.file-url"],isTargeted:nil) { providers in
                        for provider in providers { _ = provider.loadObject(ofClass:URL.self) { url, _ in if let url { Task { @MainActor in model.receiveFiles([url]) } } } }
                        return true
                    }
                VStack(alignment:.leading,spacing:10) {
                    HStack {
                        Text(model.phase == "reviewing" ? (model.organizationState == "organized" ? "完整 Prompt · 可直接编辑" : "本地整合草稿 · 可直接编辑") : "实时转写").font(.headline)
                        Spacer()
                        if model.phase == "reviewing" { Text("正文可直接编辑，推断可展开修改").font(.system(size:11)).foregroundStyle(.secondary) }
                    }
                    if model.phase == "reviewing" {
                        if !model.reviewChoices.isEmpty { ReviewChoicesView(model:model).id(model.sessionID) }
                        PromptTextEditor(text:Binding(get:{ model.prompt },set:{ model.editPrompt($0) })).font(.system(size:13)).scrollContentBackground(.hidden)
                            .frame(minHeight:120).padding(10).background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:10))
                    } else {
                        ScrollView { Text(model.liveText.isEmpty ? "语音准备好后，你可以回到原来的应用。\n这里会显示本次表达的转写。" : model.liveText)
                            .font(.system(size:16)).foregroundStyle(model.liveText.isEmpty ? .secondary : .primary)
                            .frame(maxWidth:.infinity,alignment:.leading).padding(14) }.frame(maxWidth:.infinity,maxHeight:.infinity)
                    }
                }.padding(.leading,14).frame(minWidth:400)
            }.frame(minHeight:320)
            if !model.gaps.isEmpty {
                Text("需要核对：" + model.gaps.suffix(2).joined(separator:"；")).font(.system(size:11)).foregroundStyle(.orange).lineLimit(2)
            }
            HStack {
                CodexSendControls(model:model,probe:model.desktopDelivery)
                Button("上次表达") { model.loadLatestSession() }.disabled(model.active || model.refining || model.draining || model.phase == "preparing" || model.phase == "finalizing")
                Button("打开试用页面") { openChrome("http://127.0.0.1:9876/browser.html") }
                Button("打开文件试用") {
                    let folder = model.projectRoot.appendingPathComponent("Fixtures/Finder")
                    NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("示例A.txt"),folder.appendingPathComponent("示例B.txt")])
                }
                Spacer()
                Text(model.refineNote).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack {
                Spacer()
                if model.refining { ProgressView().controlSize(.small) }
                if model.refining { Button("取消整理") { model.cancelRefinement() } }
                else { Button("整理 Prompt") { model.refine() }.disabled(model.phase != "reviewing") }
                Button("原始记录") { evidence = true }.disabled(model.phase != "reviewing")
                Button("复制 Prompt") { model.copyPrompt() }.disabled(model.phase != "reviewing")
                Button("导出全部素材") { model.export() }.disabled(model.phase != "reviewing")
                Button("会话文件夹") { model.reveal() }.disabled(model.directory == nil)
            }
        }.frame(minHeight:max(0,geometry.size.height-48),alignment:.top).padding(24)
       }
      }.sheet(isPresented:$evidence) {
            VStack(alignment:.leading,spacing:12) {
                HStack { Text("原始采集记录 · 供核对").font(.headline); Spacer(); Button("关闭") { evidence = false } }
                ScrollView { Text(model.evidencePrompt).font(.system(size:12)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
            }.padding(20).frame(width:800,height:600)
        }
        .background(Color(nsColor:.windowBackgroundColor)).onChange(of:model.prompt) { _, _ in model.scheduleSave() }
    }
    private func openChrome(_ address: String) {
        guard let url = URL(string:address) else { return }
        NSWorkspace.shared.open([url],withApplicationAt:URL(fileURLWithPath:"/Applications/Google Chrome.app"),configuration:NSWorkspace.OpenConfiguration())
    }
}
