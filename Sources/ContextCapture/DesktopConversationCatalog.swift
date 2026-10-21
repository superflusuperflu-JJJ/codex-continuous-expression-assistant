import AppKit
import PrototypeCore

extension DesktopAccessibilityProbe {
    func refreshConversations(more: Bool = false, preparePreview: Bool = false) {
        guard !busy, !more || nextCursor != nil else { return }
        busy = true; humanConfirmed = false; openedForReview = false
        message = "正在读取本机 Codex 对话列表，不加载对话正文。"
        let cursor = more ? nextCursor : nil, root = root
        let python = Bundle.main.object(forInfoDictionaryKey:"PythonExecutable") as? String ?? ""
        let project = Bundle.main.object(forInfoDictionaryKey:"ProjectRoot") as? String ?? ""
        let codex = Bundle.main.object(forInfoDictionaryKey:"CodexExecutable") as? String ?? ""
        DispatchQueue.global(qos:.userInitiated).async {
            let result = Result { () -> ([DesktopConversation],String?) in
                let folder = root.appendingPathComponent("Catalog/"+UUID().uuidString)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let output = folder.appendingPathComponent("page.json")
                let process = Process(); process.executableURL = URL(fileURLWithPath:python)
                process.arguments = [URL(fileURLWithPath:project).appendingPathComponent("tools/codex_conversations.py").path,"--codex",codex,"--output",output.path] + (cursor.map { ["--cursor",$0] } ?? [])
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run()
                let deadline = ProcessInfo.processInfo.systemUptime + 15
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval:0.05) }
                guard !process.isRunning else { process.terminate(); throw NSError(domain:"Catalog",code:1,userInfo:[NSLocalizedDescriptionKey:"读取对话列表超时"]) }
                guard process.terminationStatus == 0 else { throw NSError(domain:"Catalog",code:2,userInfo:[NSLocalizedDescriptionKey:"Codex 对话列表暂时不可用，请重试刷新"]) }
                struct Page: Decodable { let threads: [DesktopConversation]; let nextCursor: String? }
                let page = try JSONDecoder().decode(Page.self,from:Data(contentsOf:output))
                return (page.threads,page.nextCursor)
            }
            Task { @MainActor in
                self.busy = false
                switch result {
                case .success(let (rows,cursor)):
                    var seen = Set<String>()
                    self.conversations = ((more ? self.conversations : []) + rows).filter { seen.insert($0.id).inserted }
                    self.nextCursor = cursor
                    self.message = self.selectedTarget == nil ? "请选择发送目标；选定后会一直保留，直到你主动更换。" : "目标已固定；刷新或搜索不会更换发送目标。"
                    if preparePreview { self.prepareDraft() }
                case .failure(let error): self.message = error.localizedDescription
                }
            }
        }
    }
}
