import Foundation

/// Read-only, no SessionModel, native host registration, privacy prompts or Codex submissions.
enum InstallationDiagnostic {
    static func run() -> Int {
        let runtime = ApplicationRuntime.current
        var result: [String:Any] = ["portable":runtime.portable,"runtimeAvailable":false,
            "codexDetected":runtime.codexURL != nil,"desktopDetected":runtime.desktopURL != nil,
            "hostRegistrationPerformed":false,"captureServicesStarted":false]
        if let python = runtime.pythonURL {
            let process = Process();process.executableURL = python
            let modules = ["native_host","handoff_package","codex_handoff_probe","codex_conversations","prepare_desktop_draft","desktop_send_receipt","installation_probe"]
            process.arguments = ["-B","-E","-s","-c","import sys; sys.path.insert(0,sys.argv[1]); "+modules.map { "__import__('"+$0+"')" }.joined(separator:"; "),runtime.resourceRoot.appendingPathComponent("tools").path]
            process.standardOutput = FileHandle.nullDevice;process.standardError = FileHandle.nullDevice
            do { try process.run();process.waitUntilExit();result["runtimeAvailable"] = process.terminationStatus == 0 }
            catch { result["runtimeAvailable"] = false }
        }
        if let data = try? JSONSerialization.data(withJSONObject:result,options:.sortedKeys),let text = String(data:data,encoding:.utf8) { print(text) }
        return result["runtimeAvailable"] as? Bool == true ? 0 : 1
    }
}
