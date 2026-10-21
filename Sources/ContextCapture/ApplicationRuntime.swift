import AppKit

/// All installed paths are resolved relative to the running bundle, never the build machine.
struct ApplicationRuntime {
    let bundleURL: URL
    let info: [String:Any]
    let desktopURLs: [URL]
    let fallbackCLIPaths: [String]
    let overrideCLI: String?
    var portable: Bool { info["PortableDistribution"] as? Bool == true }
    static var current: Self {
        var locations = [URL(fileURLWithPath:"/Applications/ChatGPT.app"),URL(fileURLWithPath:"/Applications/Codex.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ChatGPT.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Codex.app")]
        if let discovered = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.openai.codex") { locations.insert(discovered,at:0) }
        return Self(bundleURL:Bundle.main.bundleURL,info:Bundle.main.infoDictionary ?? [:],desktopURLs:locations,
            overrideCLI:UserDefaults.standard.string(forKey:"codexExecutableOverride"))
    }
    init(bundleURL: URL, info: [String:Any], desktopURLs: [URL],
         fallbackCLIPaths: [String] = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/bin/codex").path,"/opt/homebrew/bin/codex","/usr/local/bin/codex"], overrideCLI: String? = nil) {
        self.bundleURL = bundleURL; self.info = info; self.desktopURLs = desktopURLs
        self.fallbackCLIPaths = fallbackCLIPaths; self.overrideCLI = overrideCLI
    }
    var resourceRoot: URL {
        portable ? bundleURL.appendingPathComponent("Contents/Resources/Support") : URL(fileURLWithPath:info["ProjectRoot"] as? String ?? FileManager.default.currentDirectoryPath)
    }
    var pythonURL: URL? {
        let path = portable ? bundleURL.appendingPathComponent("Contents/Resources/Python/bin/python3").path : info["PythonExecutable"] as? String
        return executable(path)
    }
    var desktopURL: URL? {
        desktopURLs.first { FileManager.default.fileExists(atPath:$0.appendingPathComponent("Contents/Info.plist").path) }
    }
    var codexURL: URL? {
        if let override = executable(overrideCLI) { return override }
        if !portable, let local = executable(info["CodexExecutable"] as? String) { return local }
        for app in desktopURLs {
            for relative in ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex","Contents/Resources/codex","Contents/MacOS/codex"] {
                if let url = executable(app.appendingPathComponent(relative).path) { return url }
            }
        }
        return fallbackCLIPaths.compactMap { executable($0) }.first
    }
    func helper(_ name: String) -> URL { resourceRoot.appendingPathComponent("tools/"+name) }
    func pythonProcess(script: String, arguments: [String]) throws -> Process {
        guard let python = pythonURL, FileManager.default.fileExists(atPath:helper(script).path) else {
            throw NSError(domain:"Installation",code:1,userInfo:[NSLocalizedDescriptionKey:"应用内置运行组件缺失，请重新安装完整应用；不会使用旧电脑路径。"])
        }
        let process = Process(); process.executableURL = python
        process.arguments = ["-B","-E","-s",helper(script).path]+arguments
        process.currentDirectoryURL = resourceRoot
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey:"PYTHONHOME"); environment.removeValue(forKey:"PYTHONPATH")
        process.environment = environment
        return process
    }
    func requireCodex() throws -> URL {
        guard let url = codexURL else { throw NSError(domain:"Installation",code:2,userInfo:[NSLocalizedDescriptionKey:"未找到兼容的 Codex 组件，请打开安装与连接向导检查。"] ) }
        return url
    }
    private func executable(_ path: String?) -> URL? {
        guard let path, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath:path) else { return nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath:path,isDirectory:&directory), !directory.boolValue else { return nil }
        return URL(fileURLWithPath:path)
    }
}
