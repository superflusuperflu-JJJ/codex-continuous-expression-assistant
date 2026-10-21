import Foundation

public struct PromptSpeech: Codable, Sendable {
    public var id: String
    public var text: String
    public var bindings: [Binding]
    public var selectedMaterialIDs: [String]
    public init(id: String, text: String, bindings: [Binding], selectedMaterialIDs: [String] = []) {
        self.id = id; self.text = text; self.bindings = bindings; self.selectedMaterialIDs = selectedMaterialIDs
    }
}

public struct PromptMaterial: Codable, Sendable {
    public var id: String
    public var kind: String
    public var label: String
    public var text: String?
    public var link: String?
    public var availability: String
    public var attachment: String?
}

public struct PromptContext: Codable, Sendable {
    public var speech: [PromptSpeech]
    public var materials: [PromptMaterial]
    public var gaps: [String]
    public init(speech: [PromptSpeech], materials: [PromptMaterial], gaps: [String]) {
        self.speech = speech; self.materials = materials; self.gaps = gaps
    }
}

public struct PromptParagraph: Codable, Sendable {
    public var text: String
    public var speechIDs: [String]
    public var materialIDs: [String]
    public init(text: String, speechIDs: [String], materialIDs: [String]) {
        self.text = text; self.speechIDs = speechIDs; self.materialIDs = materialIDs
    }
}

public struct SpeechDecision: Codable, Sendable {
    public var speechID: String
    public var disposition: String
    public var replacementSpeechIDs: [String]
    public var reason: String
    public init(_ id: String, _ disposition: String, replacements: [String] = [], reason: String = "保留要求") {
        speechID = id; self.disposition = disposition; replacementSpeechIDs = replacements; self.reason = reason
    }
}

public struct OrganizedPrompt: Codable, Sendable {
    public var paragraphs: [PromptParagraph]
    public var unresolved: [PromptParagraph]
    public var decisions: [SpeechDecision]
    public var resolutions: [PromptResolution]?
    public init(paragraphs: [PromptParagraph], unresolved: [PromptParagraph] = [], decisions: [SpeechDecision], resolutions: [PromptResolution]? = nil) {
        self.resolutions = resolutions
        self.paragraphs = paragraphs; self.unresolved = unresolved; self.decisions = decisions
    }
}

public enum PromptComposition {
    public static func context(materials: [Material], segments: [SpokenSegment], anchors: [Anchor], gaps: [String]) -> PromptContext {
        let rawAnchors = anchors
        let anchors = SelectionGrouping.normalized(materials:materials,anchors:rawAnchors)
        let speech = segments.sorted { $0.start < $1.start }.map { segment in
            PromptSpeech(id: segment.id, text: segment.text, bindings: Association.bindings(for: segment, anchors: anchors),
                selectedMaterialIDs: Array(Set(anchors.filter { $0.start <= segment.end && ($0.end ?? .infinity) >= segment.start }.flatMap(\.materialIDs))).sorted())
        }
        let protected = Set(speech.flatMap { $0.bindings.flatMap(\.materialIDs) + $0.selectedMaterialIDs })
        let ordered = anchors.sorted { $0.start < $1.start }
        let byID = Dictionary(uniqueKeysWithValues: materials.map { ($0.id, $0) })
        var hidden = Set(rawAnchors.flatMap(\.materialIDs)).subtracting(Set(anchors.flatMap(\.materialIDs)))
        for (first, next) in zip(ordered, ordered.dropFirst()) {
            guard first.source == next.source, let end = first.end, end - first.start < 0.6,
                  next.start - end < 0.15 else { continue }
            let before = first.materialIDs.compactMap { byID[$0] }.filter { $0.kind == "文字" }
            let after = next.materialIDs.compactMap { byID[$0] }.filter { $0.kind == "文字" }
            for item in before where !protected.contains(item.id) {
                let text = normalized(item.content)
                if !text.isEmpty && after.contains(where: { let other = normalized($0.content); return !other.isEmpty && (text.contains(other) || other.contains(text)) }) {
                    hidden.insert(item.id)
                }
            }
        }
        let effective = materials.filter { !hidden.contains($0.id) }.map { item in
            PromptMaterial(id:item.id, kind:item.kind, label:item.label,
                text:item.kind == "文字" ? item.content : nil, link:item.kind == "链接" ? item.content : nil,
                availability:item.availability, attachment:item.localPath.map { "assets/" + URL(fileURLWithPath:$0).lastPathComponent })
        }
        return PromptContext(speech:speech, materials:effective, gaps:gaps)
    }

    public static func validate(_ result: OrganizedPrompt, for context: PromptContext) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain:"PromptComposition",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
        }
        let speechIDs = Set(context.speech.map(\.id)), materialIDs = Set(context.materials.map(\.id))
        try require(result.decisions.count == speechIDs.count && Set(result.decisions.map(\.speechID)) == speechIDs, "每段原话必须有明确的保留或更正去向")
        let resolutions = result.resolutions ?? []
        try require(Set(resolutions.map(\.id)).count == resolutions.count, "选择卡片编号重复")
        for item in resolutions {
            try require(!item.id.isEmpty && !item.question.isEmpty && !item.reason.isEmpty && !item.speechIDs.isEmpty && !item.options.isEmpty, "选择卡片缺少问题、依据或推荐")
            try require(Set(item.speechIDs).isSubset(of:speechIDs), "选择卡片引用未知原话")
            let sources = context.speech.filter { item.speechIDs.contains($0.id) }
            let candidates = Set(sources.flatMap { $0.bindings.flatMap(\.materialIDs) + $0.selectedMaterialIDs })
            for option in item.options {
                try require(!option.label.isEmpty && !option.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, "选项不能为空")
                try require(Set(option.materialIDs).isSubset(of:materialIDs.intersection(candidates)), "选项引用了没有关联依据的素材")
                try require(references(in:option.text).isSubset(of:Set(option.materialIDs)), "选项素材编号必须声明来源")
            }
            if item.applyByDefault { try require(!item.options[0].materialIDs.isEmpty, "默认推断必须有素材依据") }
        }
        let blocks = result.paragraphs.map { PromptOption(label:"",text:$0.text,materialIDs:$0.materialIDs).instruction } + resolutions.map(\.initialBlock)
        for resolution in resolutions {
            try require(blocks.filter { $0 == resolution.initialBlock }.count == 1, "推荐要求与正文重复，无法安全更新")
            try require(resolution.position == nil || (0...result.paragraphs.count).contains(resolution.position!), "选择卡片位置越界")
            try require(!resolution.initialBlock.contains("\n\n") && resolution.options.allSatisfy { !$0.instruction.contains("\n\n") }, "选择要求必须是独立单段，避免覆盖其他段落")
        }
        let questions = Set(result.unresolved.flatMap(\.speechIDs) + resolutions.flatMap(\.speechIDs))
        let used = Set(result.paragraphs.flatMap(\.speechIDs) + resolutions.flatMap(\.speechIDs))
        let byID = Dictionary(uniqueKeysWithValues:context.speech.map { ($0.id,$0) })
        for paragraph in result.paragraphs + result.unresolved {
            try require(!paragraph.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !paragraph.speechIDs.isEmpty, "整理段落必须有原话依据")
            try require(Set(paragraph.speechIDs).isSubset(of:speechIDs) && Set(paragraph.materialIDs).isSubset(of:materialIDs), "整理结果引用了不存在的原话或素材")
            try require(references(in:paragraph.text).isSubset(of:Set(paragraph.materialIDs)), "正文素材编号必须声明来源")
        }
        for paragraph in result.paragraphs {
            let supported = Set(paragraph.speechIDs.compactMap { byID[$0] }.flatMap { speech in
                speech.bindings.isEmpty ? speech.selectedMaterialIDs : speech.bindings.filter(\.certain).flatMap(\.materialIDs)
            })
            try require(Set(paragraph.materialIDs).isSubset(of:supported), "整理结果把没有确定依据的素材写成了任务目标")
        }
        let order = Dictionary(uniqueKeysWithValues:context.speech.enumerated().map { ($0.element.id,$0.offset) })
        let dispositions = Dictionary(uniqueKeysWithValues:result.decisions.map { ($0.speechID,$0.disposition) })
        for decision in result.decisions {
            try require(!decision.reason.isEmpty, "原话取舍必须说明依据")
            switch decision.disposition {
            case "included":
                try require(used.contains(decision.speechID), "保留的原话没有进入请求正文")
                let targets = Set(byID[decision.speechID]!.bindings.filter(\.certain).flatMap(\.materialIDs))
                let represented = Set(result.paragraphs.filter { $0.speechIDs.contains(decision.speechID) }.flatMap(\.materialIDs) + resolutions.filter { $0.speechIDs.contains(decision.speechID) }.flatMap { $0.options.first?.materialIDs ?? [] })
                try require(targets.isSubset(of:represented), "整理结果遗漏了原话已经确定的素材关系")
            case "unresolved": try require(questions.contains(decision.speechID), "未决要求必须展示待确认问题")
            case "superseded":
                try require(!used.contains(decision.speechID) && !decision.replacementSpeechIDs.isEmpty, "撤回要求必须指向后续更正，不能继续作为任务")
                for replacement in decision.replacementSpeechIDs {
                    try require((order[replacement] ?? -1) > (order[decision.speechID] ?? .max) && ["included","unresolved"].contains(dispositions[replacement] ?? ""), "撤回必须有后续有效更正依据")
                }
            case "filler":
                let speech = byID[decision.speechID]!
                let filler = normalized(speech.text)
                let punctuationOnly = !speech.text.isEmpty && speech.text.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }
                try require(speech.bindings.isEmpty && (punctuationOnly || ["嗯","呃","啊","好","好的","对","对的","谢谢","结束","好了","就这样","可以了"].contains(filler)) && !used.contains(speech.id), "不能把任务要求当作口头停顿删除")
            default: try require(false, "未知的原话取舍方式")
            }
        }
        for speech in context.speech where speech.bindings.contains(where:{ !$0.certain }) {
            try require(questions.contains(speech.id), "不明确指代必须保留待确认，不能猜测")
        }
        try require(!result.paragraphs.isEmpty || !result.unresolved.isEmpty || !resolutions.isEmpty || context.speech.allSatisfy { dispositions[$0.id] == "filler" }, "整理结果为空")
    }

    public static func render(_ result: OrganizedPrompt, context: PromptContext) -> String {
        let paragraphs = result.paragraphs.map { paragraph -> String in
            let missing = paragraph.materialIDs.filter { !references(in:paragraph.text).contains($0) }
            return paragraph.text + (missing.isEmpty ? "" : "（对应素材：" + missing.map { "[\($0)]" }.joined(separator:"、") + "）")
        }
        var lines: [String] = []
        for position in 0...paragraphs.count {
            lines += (result.resolutions ?? []).filter { ($0.position ?? paragraphs.count) == position }.map(\.initialBlock)
            if position < paragraphs.count { lines.append(paragraphs[position]) }
        }
        if !result.unresolved.isEmpty { lines += ["待确认"] + result.unresolved.map { "- " + $0.text } }
        let used = Set((result.paragraphs + result.unresolved).flatMap(\.materialIDs) + (result.resolutions ?? []).flatMap { $0.options.flatMap(\.materialIDs) })
        appendMaterials(to:&lines,context:context,used:used)
        return lines.joined(separator:"\n\n")
    }

    public static func localDraft(_ context: PromptContext) -> String {
        let byID = Dictionary(uniqueKeysWithValues:context.materials.map { ($0.id,$0) })
        var requirements: [String] = [], questions: [String] = [], used = Set<String>()
        for speech in context.speech {
            let original = speech.text as NSString
            let text = NSMutableString(string:speech.text)
            var cursor = 0, edits: [(NSRange,String)] = []
            for binding in speech.bindings {
                let range = original.range(of:binding.phrase,range:NSRange(location:cursor,length:original.length-cursor))
                guard range.location != NSNotFound else { continue }
                cursor = NSMaxRange(range)
                if !binding.certain { questions.append("“\(binding.phrase)”具体指什么？"); continue }
                let items = binding.materialIDs.compactMap { byID[$0] }
                let kind = Set(items.map(\.kind)).count == 1 ? items.first?.kind ?? "素材" : "素材"
                var replacementRange = range
                if cursor + (kind as NSString).length <= original.length && original.substring(with:NSRange(location:cursor,length:(kind as NSString).length)) == kind {
                    replacementRange.length += (kind as NSString).length; cursor = NSMaxRange(replacementRange)
                }
                edits.append((replacementRange, kind + binding.materialIDs.map { "[\($0)]" }.joined(separator:"、")))
                used.formUnion(binding.materialIDs)
            }
            for (range,replacement) in edits.reversed() { text.replaceCharacters(in:range,with:replacement) }
            var line = text as String
            if !line.isEmpty && !["。","！","？","；"].contains(String(line.suffix(1))) { line += "。" }
            requirements.append(line)
        }
        var lines = [requirements.isEmpty ? "请补充本次要完成的任务。" : "请按以下要求处理：\n\n" + requirements.joined()]
        if !questions.isEmpty { lines += ["待确认"] + Array(Set(questions)).sorted().map { "- " + $0 } }
        appendMaterials(to:&lines,context:context,used:used)
        return lines.joined(separator:"\n\n")
    }

    public static func references(in text: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern:"\\[(M[0-9]+)\\]")
        let ns = text as NSString
        return Set(regex.matches(in:text,range:NSRange(location:0,length:ns.length)).map { ns.substring(with:$0.range(at:1)) })
    }
    private static func normalized(_ text: String) -> String {
        String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
    private static func appendMaterials(to lines: inout [String], context: PromptContext, used: Set<String>) {
        func description(_ item: PromptMaterial) -> String {
            var value = "[\(item.id)] \(item.kind)：" + (item.text ?? item.link ?? item.label)
            if let attachment = item.attachment { value += "（\(attachment)）" }
            if item.availability == "excerpt" { value += "；已保存页面截图，非图片原件" }
            else if item.availability != "original" { value += "；内容尚未完整取得" }
            return value
        }
        let referenced = context.materials.filter { used.contains($0.id) }
        let other = context.materials.filter { !used.contains($0.id) }
        if !referenced.isEmpty { lines += ["对应素材"] + referenced.map(description) }
        if !other.isEmpty { lines += ["另外选中的资料（尚未指定用途）"] + other.map(description) }
        if !context.gaps.isEmpty { lines += ["采集需核对"] + context.gaps.map { "- " + $0 } }
    }
}
