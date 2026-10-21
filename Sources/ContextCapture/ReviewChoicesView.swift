import SwiftUI
import PrototypeCore

extension SessionModel {
    func editPrompt(_ text: String) {
        var choices = reviewChoices
        ReviewChoices.markManualEdit(choices:&choices,oldPrompt:prompt,newPrompt:text)
        reviewChoices = choices; prompt = text
    }

    func choose(_ id: String, option: Int?, custom: String = "") {
        guard phase == "reviewing", !refining, let index = reviewChoices.firstIndex(where: { $0.id == id }) else { return }
        var choices = reviewChoices, text = prompt
        let generatedWasUnedited = prompt == originalPrompt
        let applied = ReviewChoices.apply(option,custom:custom,choice:&choices[index],prompt:&text)
        reviewChoices = choices; prompt = text
        if generatedWasUnedited && applied { originalPrompt = text }
        refineNote = applied ? "已更新对应要求，其他文字已保留。" : "对应段落已修改、删除或与其他要求重复，未覆盖；可复制所选要求后自行合入。"
        save()
    }
    func chooseAllRecommended() {
        guard phase == "reviewing", !refining else { return }
        var choices = reviewChoices, text = prompt
        let generatedWasUnedited = prompt == originalPrompt
        let count = ReviewChoices.applyRecommended(choices:&choices,prompt:&text)
        reviewChoices = choices; prompt = text
        if generatedWasUnedited { originalPrompt = text }
        let conflicts = choices.filter(\.conflict).count
        refineNote = "已采用 \(count) 项推荐，保留个人选择和自填草稿。" + (conflicts > 0 ? "\(conflicts) 项正文已修改，未覆盖。" : "")
        save()
    }
    func updateChoiceDraft(_ id: String, text: String) {
        guard let index = reviewChoices.firstIndex(where: { $0.id == id }) else { return }
        reviewChoices[index].customText = text; scheduleSave()
    }
}

struct ReviewChoicesView: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        VStack(alignment:.leading,spacing:7) {
            HStack {
                Text("判断与选择").font(.system(size:12,weight:.semibold))
                Text("\(model.reviewChoices.filter { $0.selectedIndex == nil && !$0.userChosen }.count) 项待选择").font(.system(size:11)).foregroundStyle(.secondary)
                Spacer()
                Button("一键采用全部推荐") { model.chooseAllRecommended() }.disabled(model.refining)
            }
            ScrollView {
                VStack(alignment:.leading,spacing:7) {
                    ForEach(model.reviewChoices) { choice in
                        ReviewChoiceCard(model:model,choice:choice)
                    }
                }
            }.frame(maxHeight:220)
        }
    }
}

private struct ReviewChoiceCard: View {
    @ObservedObject var model: SessionModel
    let choice: ReviewChoice
    @State private var expanded = true
    private var summary: String {
        if choice.conflict { return "正文已改动，已保留" }
        if choice.userChosen { return "已采用你的选择" }
        return choice.resolution.applyByDefault ? "已默认采用推荐，可修改" : "待选择"
    }
    var body: some View {
        DisclosureGroup(isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:7) {
                Text(choice.resolution.reason).font(.system(size:11)).foregroundStyle(.secondary).textSelection(.enabled)
                ForEach(Array(choice.resolution.options.enumerated()),id:\.offset) { index, option in
                    Button { model.choose(choice.id,option:index) } label: {
                        HStack(alignment:.top) {
                            Image(systemName:choice.selectedIndex == index ? "largecircle.fill.circle" : "circle")
                            VStack(alignment:.leading,spacing:2) {
                                Text(option.label + (index == 0 ? "（推荐）" : ""))
                                Text(option.instruction).font(.system(size:11)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.refining)
                }
                HStack {
                    TextField("自行填写这项的完整要求",text:Binding(get:{ choice.customText },set:{ model.updateChoiceDraft(choice.id,text:$0) }))
                        .textFieldStyle(.roundedBorder).disabled(model.refining)
                    Button("采用填写") { model.choose(choice.id,option:nil,custom:choice.customText) }
                        .disabled(choice.customText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || model.refining)
                }
                if choice.conflict {
                    Text("你修改过对应正文，系统不会覆盖。上方要求可以选中复制，再合入你的文字。")
                        .font(.system(size:11)).foregroundStyle(.orange)
                }
            }.padding(.top,5)
        } label: {
            VStack(alignment:.leading,spacing:2) {
                Text(choice.resolution.question).font(.system(size:12,weight:.medium))
                Text(summary).font(.system(size:10)).foregroundStyle(choice.conflict ? Color.orange : Color.secondary)
            }
        }.padding(9).background(Color.accentColor.opacity(0.045),in:RoundedRectangle(cornerRadius:8))
    }
}
