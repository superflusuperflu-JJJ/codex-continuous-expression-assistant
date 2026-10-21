import AppKit
import ApplicationServices
import PrototypeCore

/// Invoked only by the prototype after a human clicks verify/fill. No typing or sending.
enum DesktopConversationIdentity {
    static func copiedLink(pid: pid_t, window: AXUIElement) throws -> String {
        func fail(_ text: String) -> NSError { NSError(domain:"ConversationIdentity",code:1,userInfo:[NSLocalizedDescriptionKey:text]) }
        func get(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success ? value : nil
        }
        let app = AXUIElementCreateApplication(pid)
        func stable() -> Bool {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid &&
                get(app,kAXFocusedWindowAttribute).map { CFEqual($0,window) } == true
        }
        guard stable() else { throw fail("无法核对当前 Codex 窗口") }
        // Codex ships copyDeeplink as a hidden native command with
        // acceleratorWorksWhenHidden=true and CmdOrCtrl+Alt+L. It is absent
        // from the AX menu tree, so pressing an AXMenuItem cannot invoke it.
        // This fixed copy-only command is triggered by the human's button,
        // pinned to the verified front process; it never types or submits.
        guard let source = CGEventSource(stateID:.privateState),
              let down = CGEvent(keyboardEventSource:source,virtualKey:37,keyDown:true),
              let up = CGEvent(keyboardEventSource:source,virtualKey:37,keyDown:false) else {
            throw fail("无法创建复制对话链接命令，未填写")
        }
        down.flags = [.maskCommand,.maskAlternate]
        up.flags = [.maskCommand,.maskAlternate]
        let pasteboard = NSPasteboard.general
        let snapshotCount = pasteboard.changeCount
        let snapshot = pasteboard.pasteboardItems ?? []
        var restoredItems: [NSPasteboardItem] = [], bytes = 0
        guard snapshot.count <= 16 else { throw fail("剪贴板项目过多，未改动剪贴板或输入框") }
        for source in snapshot {
            let copy = NSPasteboardItem()
            for type in source.types {
                guard let data = source.data(forType:type) else { throw fail("无法完整保留剪贴板，未填写") }
                bytes += data.count
                guard bytes <= 32*1024*1024 else { throw fail("剪贴板内容过大，未改动剪贴板或输入框") }
                copy.setData(data,forType:type)
            }
            restoredItems.append(copy)
        }
        guard pasteboard.changeCount == snapshotCount else { throw fail("保留剪贴板时内容发生变化，未填写") }
        var observation = CopiedLinkObservation(initialChangeCount:snapshotCount)
        defer {
            // Never overwrite a later clipboard change made by the user or another app.
            if observation.canRestore(changeCount:pasteboard.changeCount,text:pasteboard.string(forType:.string)) {
                pasteboard.clearContents()
                if !restoredItems.isEmpty { pasteboard.writeObjects(restoredItems) }
            }
        }
        guard stable() else { throw fail("读取链接前窗口变化，未填写") }
        down.postToPid(pid)
        up.postToPid(pid)
        let copyDeadline = ProcessInfo.processInfo.systemUptime + 1
        while ProcessInfo.processInfo.systemUptime < copyDeadline {
            let result = observation.observe(changeCount:pasteboard.changeCount,text:pasteboard.string(forType:.string),windowStable:stable())
            switch result {
            case .ready(let link): return link
            case .targetChanged: throw fail("复制链接时窗口变化，已停止")
            case .waiting: break
            }
            Thread.sleep(forTimeInterval:0.04)
        }
        throw fail("未取得当前对话的深层链接，未填写")
    }
}
