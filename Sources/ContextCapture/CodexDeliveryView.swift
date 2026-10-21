import AppKit
import ApplicationServices
import SwiftUI

/// Inline target selection. Searching never implicitly changes a pinned target.
struct CodexTargetPicker: View {
    @ObservedObject var probe: DesktopAccessibilityProbe
    @State private var changing = false
    var body: some View {
        VStack(alignment:.leading,spacing:7) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:2) {
                    Text("发送到 Codex").font(.caption).foregroundStyle(.secondary)
                    Text(probe.targetTitle).font(.callout.weight(.medium)).lineLimit(1)
                    if let target = probe.selectedTarget {
                        Text(target.cwd + " · " + target.id.suffix(8))
                            .font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1)
                            .help(target.cwd + "\n" + target.id)
                    }
                }
                Spacer(minLength:4)
                if probe.selectedTarget != nil {
                    Button(changing ? "收起" : "更换") { changing.toggle() }.disabled(probe.busy)
                }
            }
            if changing || probe.selectedTarget == nil {
                HStack {
                    TextField("搜索对话标题、项目或 ID",text:$probe.search)
                    Button("刷新") { probe.refreshConversations() }
                }.disabled(probe.busy)
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:4) {
                        ForEach(probe.filteredConversations) { chat in
                            Button {
                                probe.selectedID = chat.id
                                changing = false
                            } label: {
                                HStack(alignment:.top,spacing:6) {
                                    Image(systemName:probe.selectedID == chat.id ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment:.leading,spacing:2) {
                                        Text(chat.name).lineLimit(1)
                                        Text(chat.cwd + " · " + chat.id.suffix(8)).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength:0)
                                }.padding(5).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(probe.busy)
                        }
                        if probe.filteredConversations.isEmpty {
                            Text(probe.busy ? "正在读取对话…" : "暂无匹配对话，可刷新或加载更多。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(height:110)
                if probe.nextCursor != nil {
                    Button("加载更多对话") { probe.refreshConversations(more:true) }.font(.caption).disabled(probe.busy)
                }
            }
        }.onAppear { if probe.conversations.isEmpty && !probe.busy { probe.refreshConversations() } }
    }
}

struct CodexSendControls: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var probe: DesktopAccessibilityProbe
    var onWillFill: (() -> Void)? = nil
    var onFillFailure: (() -> Void)? = nil
    private var available: Bool {
        !probe.busy && probe.selectedTarget != nil && model.directory != nil && model.phase == "reviewing" &&
        !model.active && !model.refining && !model.draining && !model.prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        VStack(alignment:.leading,spacing:5) {
            HStack {
                if probe.busy { ProgressView().controlSize(.small) }
                Text(probe.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength:0)
            }
            HStack {
                if !AXIsProcessTrusted() { Button("允许辅助功能") { probe.permission() }.font(.caption).disabled(probe.busy) }
                Spacer()
                Button(probe.busy ? "请稍候…" : "发送到 Codex") {
                    probe.onWillFill = onWillFill; probe.onDidSend = onWillFill; probe.onFillFailure = onFillFailure
                    probe.sendCurrentPrompt(session:model.directory,prompt:model.prompt,materials:model.materials)
                }.buttonStyle(.borderedProminent).disabled(!available)
            }
            if probe.reportURL != nil {
                DisclosureGroup("发送详情") {
                    Text(probe.message).font(.caption).textSelection(.enabled)
                    Text("目标 ID：" + probe.targetID).font(.system(size:10,design:.monospaced)).textSelection(.enabled)
                    if let url = probe.reportURL { Button("查看诊断报告") { NSWorkspace.shared.open(url) }.font(.caption) }
                }.font(.caption)
            }
        }
    }
}
