import SwiftUI

struct TrialSetupView: View {
    @ObservedObject var setup: TrialSetupModel
    var finish: () -> Void
    var viewMain: () -> Void
    private let timer = Timer.publish(every:3,on:.main,in:.common).autoconnect()
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            VStack(alignment:.leading,spacing:6) {
                Text("欢迎使用 Codex连续表达助手").font(.title2.weight(.semibold))
                Text("准备一次，之后边操作、边表达即可。所有功能都会保留；账号与系统权限由你亲自确认。").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    ForEach(setup.checks) { item in
                        HStack(alignment:.top,spacing:12) {
                            Image(systemName:item.ready ? "checkmark.circle.fill" : "circle").foregroundStyle(item.ready ? .green : .secondary).padding(.top,2)
                            VStack(alignment:.leading,spacing:4) {
                                Text(item.title).font(.headline)
                                Text(item.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                if item.id == "browser", !item.ready {
                                    Text("① 打开扩展管理，开启右上角「开发者模式」。\n② 点击「加载已解压的扩展程序」，选择扩展文件夹。\n③ 如 Chrome 询问网页读取权限，请允许；再打开试用页面，回这里查看连接状态。").font(.callout)
                                    HStack {
                                        Button("扩展管理") { setup.openExtensionManager() }
                                        Button("扩展文件夹") { setup.extensionFolder() }
                                        Button("打开试用页面") { setup.openTestPage() }
                                    }
                                }
                            }.frame(maxWidth:.infinity,alignment:.leading)
                            if !item.ready && !["system","runtime","browser"].contains(item.id) {
                                Button(actionLabel(item.id)) { setup.act(item.id) }.disabled(item.id == "speech" && setup.preparingSpeech)
                            }
                        }
                        Divider()
                    }
                }.padding(.trailing,8)
            }
            if !setup.actionMessage.isEmpty { Text(setup.actionMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button("重新检查") { setup.refresh() }.disabled(setup.refreshing)
                if setup.refreshing || setup.preparingSpeech { ProgressView().controlSize(.small) }
                Menu("其他操作") {
                    Button("手动选择 Codex 组件…") { setup.chooseCLI() }
                    Button("先查看主界面（尚未完成设置）") { viewMain() }
                }
                Spacer()
                Button("完成设置，开始使用") { finish() }.buttonStyle(.borderedProminent).disabled(!setup.canFinish)
            }
        }.padding(24).frame(minWidth:640,idealWidth:700,minHeight:620,idealHeight:720)
         .onAppear { setup.refresh() }
         .onReceive(timer) { _ in if setup.pollingEnabled { setup.refresh() } }
    }
    private func actionLabel(_ id: String) -> String {
        switch id {
        case "codex":return "打开 / 安装"
        case "login":return "登录"
        case "chrome":return "安装 Chrome"
        case "speech":return "准备模型"
        default:return "允许"
        }
    }
}
