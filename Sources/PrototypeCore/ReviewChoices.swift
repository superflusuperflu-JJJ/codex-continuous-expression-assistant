import Foundation

public struct PromptOption: Codable, Sendable {
    public var label: String
    /// A complete replacement instruction, not just the name of the selected object.
    public var text: String
    public var materialIDs: [String]
    public init(label: String, text: String, materialIDs: [String]) {
        self.label = label; self.text = text; self.materialIDs = materialIDs
    }
    public var instruction: String {
        let missing = materialIDs.filter { !PromptComposition.references(in:text).contains($0) }
        return text + (missing.isEmpty ? "" : "（对应素材：" + missing.map { "[\($0)]" }.joined(separator:"、") + "）")
    }
}

public struct PromptResolution: Codable, Sendable, Identifiable {
    public var id: String
    public var question: String
    public var reason: String
    public var speechIDs: [String]
    /// First option is the recommendation. Other options must be real alternatives.
    public var options: [PromptOption]
    public var applyByDefault: Bool
    public var position: Int?
    public var initialBlock: String {
        applyByDefault ? options[0].instruction : "【待选择 · \(id)】\(question)\n推荐理解（尚未采用）：\(options[0].instruction)"
    }
}

public struct ReviewChoice: Codable, Sendable, Identifiable {
    public var resolution: PromptResolution
    public var selectedIndex: Int?
    public var customText = ""
    public var appliedBlock: String
    public var userChosen = false
    public var conflict = false
    public var protectedByUser: Bool?
    public var id: String { resolution.id }
    public init(_ resolution: PromptResolution) {
        self.resolution = resolution
        selectedIndex = resolution.applyByDefault ? 0 : nil
        appliedBlock = resolution.initialBlock
    }
}

public enum ReviewChoices {
    /// Three-way patch: only an unchanged, unique whole paragraph is managed.
    /// An edited/deleted paragraph is left alone, including when applying all recommendations.
    @discardableResult public static func apply(_ index: Int?, custom: String = "", choice: inout ReviewChoice, prompt: inout String) -> Bool {
        guard choice.protectedByUser != true else { choice.conflict = true; return false }
        let next: String
        if let index {
            guard choice.resolution.options.indices.contains(index) else { return false }
            next = choice.resolution.options[index].instruction
        } else {
            next = custom.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !next.isEmpty else { return false }
        }
        let matches = ranges(of:choice.appliedBlock,in:prompt)
        guard matches.count == 1 else { choice.conflict = true; return false }
        let others = ranges(of:next,in:prompt).filter { NSIntersectionRange($0,matches[0]).length == 0 }
        guard others.isEmpty else { choice.conflict = true; return false }
        let padded = NSMutableString(string:"\n\n" + prompt + "\n\n")
        padded.replaceCharacters(in:matches[0],with:next)
        prompt = padded.substring(with:NSRange(location:2,length:padded.length-4))
        choice.appliedBlock = next; choice.selectedIndex = index; choice.customText = custom
        choice.userChosen = true; choice.conflict = false
        return true
    }
    public static func markManualEdit(choices: inout [ReviewChoice], oldPrompt: String, newPrompt: String) {
        guard oldPrompt != newPrompt else { return }
        let old = Array(oldPrompt.utf16), new = Array(newPrompt.utf16)
        var prefix = 0
        while prefix < min(old.count,new.count) && old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count-prefix,new.count-prefix) && old[old.count-1-suffix] == new[new.count-1-suffix] { suffix += 1 }
        let editEnd = old.count-suffix
        for index in choices.indices {
            let matches = ranges(of:choices[index].appliedBlock,in:oldPrompt)
            guard matches.count == 1 else { choices[index].protectedByUser = true; choices[index].conflict = true; continue }
            let start = matches[0].location-2, end = start+matches[0].length
            let remainsUnique = ranges(of:choices[index].appliedBlock,in:newPrompt).count == 1
            if !remainsUnique || (prefix < end && editEnd > start) {
                choices[index].protectedByUser = true; choices[index].conflict = true
            }
        }
    }
    private static func ranges(of block: String, in prompt: String) -> [NSRange] {
        let padded = "\n\n" + prompt + "\n\n"
        let pattern = "(?<=\n\n)" + NSRegularExpression.escapedPattern(for:block) + "(?=\n\n)"
        let regex = try! NSRegularExpression(pattern:pattern)
        return regex.matches(in:padded,range:NSRange(location:0,length:(padded as NSString).length)).map(\.range)
    }
    @discardableResult public static func applyRecommended(choices: inout [ReviewChoice], prompt: inout String) -> Int {
        var applied = 0
        for index in choices.indices where !choices[index].userChosen && choices[index].customText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            if apply(0,choice:&choices[index],prompt:&prompt) { applied += 1 }
        }
        return applied
    }
}
