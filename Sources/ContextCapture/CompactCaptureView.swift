import AppKit
import SwiftUI

struct CompactCaptureView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var settings: EdgePanelSettings
    let onWillFill: () -> Void
    let onFillFailure: () -> Void
    @State private var materialsExpanded = false
    @State private var toolsExpanded = false
    private var transitioning: Bool { model.phase == "preparing" || model.phase == "finalizing" || model.refining || model.draining }
    var body: some View {
      GeometryReader { geometry in
       ScrollView {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("连续表达").font(.title3.weight(.semibold))
                Spacer()
                Button { settings.openSettings?() } label: { Image(systemName:"gearshape") }.help("设置")
            }
            HStack(alignment:.top) {
                Circle().fill(model.active ? .green : .secondary).frame(width:8,height:8).padding(.top,5)
                Text(model.status).font(.callout).lineLimit(3)
                Spacer(minLength:0)
            }
            HStack {
                Text("⌘⇧Return 开始／结束").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.active {
                    Button(model.autoOrganize ? "结束并整理" : "结束表达") { model.finish() }.buttonStyle(.borderedProminent)
                } else if model.phase == "preparing" {
                    Button("取消准备") { model.cancelPreparation() }
                } else {
                    Button(transitioning ? "正在整理…" : "开始表达") { model.start() }.disabled(transitioning).buttonStyle(.borderedProminent)
                }
            }
            if model.refining { ProgressView().controlSize(.small) }
            Divider()
            CodexTargetPicker(probe:model.desktopDelivery)
            DisclosureGroup("本次素材 · \(model.visibleMaterials.count)",isExpanded:$materialsExpanded) {
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:8) {
                        if model.visibleMaterials.isEmpty { Text("选中文字、图片、链接或文件，素材会出现在这里。也可以拖入文件。").foregroundStyle(.secondary) }
                        ForEach(model.visibleMaterials) { item in
                            VStack(alignment:.leading,spacing:3) {
                                Text("\(item.id) · \(item.kind)").font(.caption).foregroundStyle(.secondary)
                                Text(item.label).lineLimit(2)
                            }.frame(maxWidth:.infinity,alignment:.leading)
                        }
                    }.font(.callout)
                }.frame(maxHeight:110)
            }.onDrop(of:["public.file-url"],isTargeted:nil) { providers in
                for provider in providers { _ = provider.loadObject(ofClass:URL.self) { url,_ in if let url { Task { @MainActor in model.receiveFiles([url]) } } } }
                return true
            }
            if model.phase == "reviewing" {
                Text("最终 Prompt").font(.headline)
                if !model.reviewChoices.isEmpty { ReviewChoicesView(model:model).id(model.sessionID).frame(maxHeight:145) }
                PromptTextEditor(text:Binding(get:{model.prompt},set:{model.editPrompt($0)}))
                    .font(.system(size:13)).scrollContentBackground(.hidden).padding(8)
                    .background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:10))
                    .frame(minHeight:100,maxHeight:.infinity)
            } else {
                Text("实时转写").font(.headline)
                ScrollView {
                    Text(model.liveText.isEmpty ? "选中素材，自然说。\n鼠标离开后自动收起，表达会继续。" : model.liveText)
                        .font(.system(size:14)).foregroundStyle(model.liveText.isEmpty ? .secondary : .primary)
                        .frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxHeight:.infinity)
            }
            if !model.gaps.isEmpty { Text(model.gaps.suffix(1).joined()).font(.caption).foregroundStyle(.orange).lineLimit(2) }
            DisclosureGroup("更多",isExpanded:$toolsExpanded) {
                VStack(alignment:.leading,spacing:8) {
                    Toggle("语音",isOn:$model.voiceEnabled).disabled(model.active || transitioning)
                    Toggle("结束后自动整理 Prompt",isOn:$model.autoOrganize).disabled(model.active || transitioning)
                    HStack {
                        Button("上次表达") { model.loadLatestSession() }.disabled(model.active || transitioning)
                        Button("复制 Prompt") { model.copyPrompt() }.disabled(model.phase != "reviewing")
                        Button("会话文件夹") { model.reveal() }.disabled(model.directory == nil)
                    }
                    if model.refining { Button("取消整理") { model.cancelRefinement() } }
                    else { Button("重新整理") { model.refine() }.disabled(model.phase != "reviewing") }
                    if !model.accessibility { Button("允许辅助功能") { model.askAccessibility() } }
                    Text(model.browserConnected ? "浏览器已连接" : "浏览器未连接，请检查扩展").font(.caption).foregroundStyle(.secondary)
                }
            }.font(.callout)
            CodexSendControls(model:model,probe:model.desktopDelivery,onWillFill:onWillFill,onFillFailure:onFillFailure)
        }.frame(minHeight:max(0,geometry.size.height-36),alignment:.top).padding(18)
       }
      }
        .onChange(of:model.prompt) { _,_ in model.scheduleSave() }
    }
}
