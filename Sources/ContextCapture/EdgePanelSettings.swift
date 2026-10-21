import AppKit
import SwiftUI

@MainActor final class EdgePanelSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var enabled: Bool {
        didSet { defaults.set(enabled,forKey:"rightEdgeAutoHide"); changed?() }
    }
    var changed: (() -> Void)?
    var openSettings: (() -> Void)?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults; enabled = defaults.bool(forKey:"rightEdgeAutoHide")
    }
}
struct EdgePanelSettingsView: View {
    @ObservedObject var settings: EdgePanelSettings
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("窗口与侧栏").font(.title2.weight(.semibold))
            Toggle("靠屏幕右侧自动隐藏",isOn:$settings.enabled)
            Text("开启后，鼠标在屏幕右侧边缘短暂停留即可展开；离开面板后自动收起。语音采集与编辑内容会保留。").foregroundStyle(.secondary)
            Text("也可从菜单栏“查看 Prompt”或 ⌘0 重新打开。关闭此选项即可恢复普通窗口。").font(.callout).foregroundStyle(.secondary)
            Text("动画遵循系统“减少动态效果”设置。").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width:380)
    }
}
