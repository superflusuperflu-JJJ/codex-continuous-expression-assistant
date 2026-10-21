import Foundation

func runtimeInstallationChecks(_ check: (Bool, String) -> Void) {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-check-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:temp) }
    let app = temp.appendingPathComponent("移动 app's 目录/助手.app")
    let python = app.appendingPathComponent("Contents/Frameworks/Python/bin/python3")
    try! FileManager.default.createDirectory(at:python.deletingLastPathComponent(),withIntermediateDirectories:true)
    FileManager.default.createFile(atPath:python.path,contents:Data("#!/bin/sh\nexit 0\n".utf8),attributes:[.posixPermissions:0o755])
    let runtime = ApplicationRuntime(bundleURL:app,info:["PortableDistribution":true,"ProjectRoot":"/private/build-only","PythonExecutable":"/private/python"],desktopURLs:[])
    check(runtime.resourceRoot == app.appendingPathComponent("Contents/Resources/Support"),"分发版从应用内部定位资源，不使用构建机路径")
    check(runtime.pythonURL == python,"移动到带空格与中文路径后仍定位内置 Python")
    check(runtime.helper("prepare_desktop_draft.py").path.hasPrefix(app.path),"素材准备脚本位于应用内部")
    try! FileManager.default.removeItem(at:python)
    check(runtime.pythonURL == nil,"分发版缺少内置 Python 时不退回构建机 Python")
    let cli = temp.appendingPathComponent("Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
    try! FileManager.default.createDirectory(at:cli.deletingLastPathComponent(),withIntermediateDirectories:true)
    FileManager.default.createFile(atPath:cli.path,contents:Data(),attributes:[.posixPermissions:0o755])
    let discovery = ApplicationRuntime(bundleURL:app,info:["PortableDistribution":true],desktopURLs:[temp.appendingPathComponent("Codex.app")],fallbackCLIPaths:[])
    check(discovery.codexURL == cli,"自动发现 Codex 桌面内置 CLI，无需朋友安装命令行工具")
    let resources = temp.appendingPathComponent("resources ' 中文")
    let extensionSource = resources.appendingPathComponent("BrowserExtension")
    try! FileManager.default.createDirectory(at:extensionSource,withIntermediateDirectories:true)
    let project = ApplicationRuntime.current.resourceRoot
    for name in ["manifest.json","background.js","content.js","public-key.txt"] {
        try! FileManager.default.copyItem(at:project.appendingPathComponent("BrowserExtension/"+name),to:extensionSource.appendingPathComponent(name))
    }
    let hostScript = resources.appendingPathComponent("tools/native_host.py")
    try! FileManager.default.createDirectory(at:hostScript.deletingLastPathComponent(),withIntermediateDirectories:true)
    try! Data("print('host')".utf8).write(to:hostScript)
    do {
        let support = temp.appendingPathComponent("support ' 中文"), manifests = temp.appendingPathComponent("manifests")
        let installation = try BrowserInstallation.install(resourceRoot:resources,pythonURL:cli,support:support,manifestDirectory:manifests)
        let object = try JSONSerialization.jsonObject(with:Data(contentsOf:installation.manifestURL)) as! [String:Any]
        check(installation.extensionID.count == 32 && (object["allowed_origins"] as? [String]) == ["chrome-extension://"+installation.extensionID+"/"],"扩展 ID 从公开密钥推导，宿主仅允许该扩展")
        let host = support.appendingPathComponent("native-host")
        let wrapper = try String(contentsOf:host,encoding:.utf8)
        check(wrapper.contains("'\"'\"'") && wrapper.hasPrefix("#!/bin/sh\nexec "),"浏览器宿主正确引用带单引号与空格的路径")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to:cli)
        let process = Process();process.executableURL = host
        let output = Pipe();process.standardOutput = output;process.standardError = FileHandle.nullDevice
        try process.run();process.waitUntilExit()
        let echoed = String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
        check(process.terminationStatus == 0 && echoed == "-B\n-E\n-s\n"+hostScript.path+"\n","宿主从带引号路径实际执行，参数不被 shell 拆分")
        let movedPython = temp.appendingPathComponent("moved/python3")
        _ = try BrowserInstallation.install(resourceRoot:resources,pythonURL:movedPython,support:support,manifestDirectory:manifests)
        check((try String(contentsOf:host,encoding:.utf8)).contains(movedPython.path),"移动应用后重新注册当前路径，不保留旧安装路径")
    } catch { check(false,"浏览器本机宿主安装：\(error)") }
    check(!TrialReadiness.canFinish(readyIDs:["system","runtime","codex","login","accessibility","microphone","speech","finder","chrome"]),"只复制扩展文件不能完成引导，必须浏览器实际连接")
    check(TrialReadiness.canFinish(readyIDs:Set(TrialReadiness.requiredIDs)),"只有全部必要检查通过才标记设置完成")
    check(TrialLaunchGuard.installationRequired(path:"/private/var/folders/example/AppTranslocation/id/d/助手.app"),"下载转置目录启动时提示安装，不注册临时路径")
    check(TrialLaunchGuard.installationRequired(path:"/Volumes/安装盘/助手.app") && TrialLaunchGuard.installationRequired(path:"/somewhere/助手.app",volumeReadOnly:true),"只读卷和安装磁盘启动时不启动正常采集服务")
    check(!TrialLaunchGuard.installationRequired(path:"/Applications/Codex连续表达助手.app"),"正常应用程序目录允许启动")
    let dev = ApplicationRuntime(bundleURL:app,info:["ProjectRoot":temp.path,"PythonExecutable":cli.path,"CodexExecutable":cli.path],desktopURLs:[])
    check(dev.resourceRoot.path == temp.path && dev.pythonURL == cli && dev.codexURL == cli,"开发版本继续兼容现有本机配置")
}
