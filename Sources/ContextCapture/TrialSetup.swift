import AppKit
import ApplicationServices
import AVFoundation
import Speech
import Carbon

struct TrialReadiness {
    static let requiredIDs = ["system","runtime","codex","login","chrome","browser","accessibility","microphone","speech","finder"]
    static func canFinish(readyIDs: Set<String>) -> Bool { Set(requiredIDs).isSubset(of:readyIDs) }
}
struct TrialSetupCheck: Identifiable {
    let id: String, title: String, detail: String
    let ready: Bool
}

@MainActor final class TrialSetupModel: ObservableObject {
    @Published var checks: [TrialSetupCheck] = []
    @Published var refreshing = false
    @Published var actionMessage = ""
    @Published var preparingSpeech = false
    private var login: Process?
    private var registrationError: String?
    var pollingEnabled = false
    let session: SessionModel
    init(session: SessionModel) { self.session = session }
    var canFinish: Bool { TrialReadiness.canFinish(readyIDs:Set(checks.filter(\.ready).map(\.id))) }
    func registerBrowser() {
        let runtime = ApplicationRuntime.current
        guard runtime.portable else { return }
        do {
            guard let python = runtime.pythonURL else { throw NSError(domain:"Install",code:1,userInfo:[NSLocalizedDescriptionKey:"内置运行组件缺失"]) }
            _ = try BrowserInstallation.install(resourceRoot:runtime.resourceRoot,pythonURL:python,support:session.root,
                manifestDirectory:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts"))
            registrationError = nil
        } catch { registrationError = error.localizedDescription }
    }
    func refresh() {
        guard !refreshing else { return }; refreshing = true
        Task {
            let runtime = ApplicationRuntime.current
            var systemOK = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
            #if !arch(arm64)
            systemOK = false
            #endif
            let installed = await SpeechTranscriber.installedLocales
            let speechReady = SpeechTranscriber.isAvailable && installed.contains { $0.language.languageCode?.identifier == "zh" && $0.region?.identifier == "CN" }
            let runtimeReady = runtime.pythonURL != nil && ["prepare_desktop_draft.py","codex_conversations.py","desktop_send_receipt.py","installation_probe.py","native_host.py"].allSatisfy { FileManager.default.fileExists(atPath:runtime.helper($0).path) }
            let codex = runtime.codexURL
            let probe = await Task.detached { () -> [String:Any] in
                guard let codex, let process = try? runtime.pythonProcess(script:"installation_probe.py",arguments:["--codex",codex.path]) else { return [:] }
                let pipe = Pipe();process.standardOutput = pipe;process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let deadline = ProcessInfo.processInfo.systemUptime+22
                    while process.isRunning && ProcessInfo.processInfo.systemUptime<deadline { try? await Task.sleep(for:.milliseconds(50)) }
                    if process.isRunning { process.terminate(); return [:] }
                    return (try? JSONSerialization.jsonObject(with:pipe.fileHandleForReading.readDataToEndOfFile())) as? [String:Any] ?? [:]
                } catch { return [:] }
            }.value
            let microphone = AVCaptureDevice.authorizationStatus(for:.audio) == .authorized
            session.accessibility = AXIsProcessTrusted()
            let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.google.Chrome") != nil
            let finder = Self.finderPermission(ask:false) == noErr
            checks = [
                .init(id:"system",title:"Mac 与系统",detail:systemOK ? "Apple Silicon · macOS 26 或以上" : "需要 Apple Silicon Mac 与 macOS 26 或以上。",ready:systemOK),
                .init(id:"runtime",title:"应用组件",detail:runtimeReady ? "运行组件已随应用安装，无需另外安装 Python。" : "组件缺失，请重新下载完整应用。",ready:runtimeReady),
                .init(id:"codex",title:"Codex 桌面连接",detail:probe["compatible"] as? Bool == true && runtime.desktopURL != nil ? (probe["version"] as? String ?? "已找到兼容组件") : "请安装或更新 Codex 桌面端；找不到组件时可手动选择 Codex 可执行文件。",ready:probe["compatible"] as? Bool == true && runtime.desktopURL != nil),
                .init(id:"login",title:"Codex 账号",detail:probe["loggedIn"] as? Bool == true ? "已登录；整理请求会使用你的账号额度。" : "请登录自己的 Codex 账号，完成后重新检查。",ready:probe["loggedIn"] as? Bool == true),
                .init(id:"chrome",title:"Chrome",detail:registrationError ?? (chrome ? "本机连接已准备。" : "请先安装 Google Chrome。"),ready:chrome && registrationError == nil),
                .init(id:"browser",title:"浏览器扩展",detail:session.browserConnected ? "已收到浏览器实际连接。" : "在 Chrome 加载扩展后，打开普通网页，等待连接。",ready:session.browserConnected),
                .init(id:"accessibility",title:"辅助功能",detail:session.accessibility ? "已允许核对目标与发送请求。" : "用于读取选中文字、核对并操作你选定的 Codex 对话。",ready:session.accessibility),
                .init(id:"microphone",title:"麦克风",detail:microphone ? "已允许本次表达录音。" : "只在开始表达后录音，首次需你允许。",ready:microphone),
                .init(id:"speech",title:"中文语音模型",detail:speechReady ? "本地中文模型已就绪。" : "首次需要下载系统中文模型，请保持网络连接。",ready:speechReady),
                .init(id:"finder",title:"Finder 文件选择",detail:finder ? "已允许读取选中文件。" : "用于将 Finder 中选中的文件与你的表达关联。",ready:finder)
            ]
            refreshing = false
        }
    }
    nonisolated static func finderPermission(ask: Bool) -> OSStatus {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier:"com.apple.finder")
        return AEDeterminePermissionToAutomateTarget(descriptor.aeDesc,typeWildCard,typeWildCard,ask)
    }
    func act(_ id: String) {
        switch id {
        case "codex":
            if let app = ApplicationRuntime.current.desktopURL { NSWorkspace.shared.open(app) }
            else { NSWorkspace.shared.open(URL(string:"https://developers.openai.com/codex/app/")!) }
        case "login":
            guard login?.isRunning != true, let executable = ApplicationRuntime.current.codexURL else { actionMessage = "请先安装 Codex 桌面端。"; return }
            let process = Process();process.executableURL = executable; process.arguments = ["login"]
            process.standardInput = FileHandle.nullDevice;process.standardOutput = FileHandle.nullDevice;process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.refresh() } }
            do { try process.run(); login = process; actionMessage = "请在打开的官方登录页面完成登录，然后回这里重新检查。" }
            catch { actionMessage = "无法启动登录，请打开 Codex 桌面端完成登录。" }
        case "chrome":
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.google.Chrome") != nil { registerBrowser();refresh() }
            else { NSWorkspace.shared.open(URL(string:"https://www.google.com/chrome/")!) }
        case "browser": openExtensionManager()
        case "accessibility": session.askAccessibility()
        case "microphone":
            if AVCaptureDevice.authorizationStatus(for:.audio) == .denied || AVCaptureDevice.authorizationStatus(for:.audio) == .restricted {
                NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            } else { Task { _ = await AVCaptureDevice.requestAccess(for:.audio); refresh() } }
        case "speech": prepareSpeech()
        case "finder":
            Task.detached {
                let permission = Self.finderPermission(ask:true)
                await MainActor.run {
                    if permission != noErr { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!) }
                    self.refresh()
                }
            }
        default: break
        }
    }
    func chooseCLI() {
        let picker = NSOpenPanel(); picker.title = "选择 Codex 可执行文件";picker.canChooseDirectories = false
        if picker.runModal() == .OK, let url = picker.url, FileManager.default.isExecutableFile(atPath:url.path) {
            UserDefaults.standard.set(url.path,forKey:"codexExecutableOverride");refresh()
        }
    }
    func openExtensionManager() {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.google.Chrome") else { actionMessage = "请先安装 Chrome。"; return }
        NSWorkspace.shared.open([URL(string:"chrome://extensions")!],withApplicationAt:chrome,configuration:NSWorkspace.OpenConfiguration())
    }
    func extensionFolder() { NSWorkspace.shared.open(session.root.appendingPathComponent("BrowserExtension")) }
    func openTestPage() {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.google.Chrome") else { return }
        NSWorkspace.shared.open([URL(string:"http://127.0.0.1:9876/browser.html")!],withApplicationAt:chrome,configuration:NSWorkspace.OpenConfiguration())
    }
    func prepareSpeech() {
        guard !preparingSpeech else { return }; preparingSpeech = true
        Task {
            do {
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo:Locale(identifier:"zh-CN")) else { throw NSError(domain:"Speech",code:1,userInfo:[NSLocalizedDescriptionKey:"本机不支持中文语音模型。"]) }
                let transcriber = SpeechTranscriber(locale:locale,transcriptionOptions:[],reportingOptions:[.volatileResults],attributeOptions:[.audioTimeRange,.transcriptionConfidence])
                actionMessage = "正在准备中文模型；首次下载可能需要几分钟。"
                if let request = try await AssetInventory.assetInstallationRequest(supporting:[transcriber]) { try await request.downloadAndInstall() }
                actionMessage = "中文语音模型已准备。"
            } catch { actionMessage = "语音准备未完成："+error.localizedDescription }
            preparingSpeech = false;refresh()
        }
    }
}
