import Foundation

public struct Material: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var label: String
    public var source: String
    public var content: String
    public var localPath: String?
    public var availability: String
    public var evidenceDigest: String?
    public init(id: String, kind: String, label: String, source: String, content: String,
                localPath: String? = nil, availability: String = "original", evidenceDigest: String? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.source = source
        self.content = content; self.localPath = localPath; self.availability = availability; self.evidenceDigest = evidenceDigest
    }
}

public struct Anchor: Codable, Sendable {
    public var materialIDs: [String]
    public var start: Double
    public var end: Double?
    public var source: String
    public var uncertainty: Double
    public var endUncertainty: Double?
    public var selectionID: String?
    public var selectionComplete: Bool?
    public var selectionStart: Double?
    public init(_ ids: [String], start: Double, end: Double? = nil, source: String = "test", uncertainty: Double = 0, endUncertainty: Double? = nil,
                selectionID: String? = nil, selectionComplete: Bool? = nil, selectionStart: Double? = nil) {
        self.selectionID = selectionID; self.selectionComplete = selectionComplete; self.selectionStart = selectionStart
        self.endUncertainty = endUncertainty
        materialIDs = ids; self.start = start; self.end = end; self.source = source; self.uncertainty = uncertainty
    }
}

public struct TimedWord: Codable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(_ text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

public struct SpokenSegment: Codable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var start: Double
    public var end: Double
    public var words: [TimedWord]
    public init(id: String = UUID().uuidString, text: String, start: Double, end: Double, words: [TimedWord] = []) {
        self.id = id; self.text = text; self.start = start; self.end = end; self.words = words
    }
}

extension SpokenSegment {
    public func hasSpeech(after cutoff: Double) -> Bool {
        let timed = words.filter { $0.end > $0.start && $0.text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) }
        return (timed.map(\.end).max() ?? end) > cutoff + 0.001
    }
}

public struct Binding: Codable, Equatable, Sendable {
    public var phrase: String
    public var materialIDs: [String]
    public var certain: Bool
    public var explanation: String
    public init(phrase: String, materialIDs: [String], certain: Bool, explanation: String) {
        self.phrase = phrase; self.materialIDs = materialIDs; self.certain = certain; self.explanation = explanation
    }
}

public enum Association {
    public static func bindings(for segment: SpokenSegment, anchors: [Anchor]) -> [Binding] {
        let regex = try! NSRegularExpression(pattern: "这一段|这段|这两个|这些|这个|这里|这张|这份|刚才那个|刚才|上一个|前一个|那个|那张|那份|它")
        let ns = segment.text as NSString
        let matches = regex.matches(in: segment.text, range: NSRange(location: 0, length: ns.length))
        var offset = 0
        let wordRanges: [(NSRange, TimedWord)] = segment.words.map { word in
            let range = NSRange(location: offset, length: (word.text as NSString).length)
            offset += range.length; return (range, word)
        }
        let historical = ["刚才", "上一个", "前一个", "不是", "不用这个", "别用这个"].contains { segment.text.contains($0) }
        return matches.map { match in
            let phrase = ns.substring(with: match.range)
            let words = wordRanges.filter { NSIntersectionRange($0.0, match.range).length > 0 }.map(\.1)
            let start = words.map(\.start).min() ?? segment.start
            let end = words.map(\.end).max() ?? segment.end
            let relevant = anchors.filter { $0.start - $0.uncertainty <= end && ($0.end ?? .infinity) + ($0.endUncertainty ?? $0.uncertainty) >= start }
            let ids = Array(Set(relevant.flatMap(\.materialIDs))).sorted()
            let stable = relevant.count == 1 && relevant[0].start + relevant[0].uncertainty <= start &&
                (relevant[0].end ?? .infinity) - (relevant[0].endUncertainty ?? relevant[0].uncertainty) >= end
            let certain = stable && !historical && !ids.isEmpty
            return Binding(phrase: phrase, materialIDs: ids, certain: certain,
                explanation: certain ? "话语发生时只有这一组明确选区" : historical ? "含历史指代或更正，请核对目标" : "选区变化、缺少短语计时或没有明确目标，请核对")
        }
    }
}

public enum PromptRenderer {
    public static func render(materials: [Material], segments: [SpokenSegment], anchors: [Anchor], gaps: [String]) -> String {
        var lines = ["请根据以下用户表达和对应素材理解本次请求。", "保留用户的否定、更正与限制；存在待确认指代时先澄清，不自行猜测。", "", "用户表达（按发生顺序）"]
        if segments.isEmpty { lines.append("尚无语音转写，请补充本次要求。") }
        let selections = SelectionGrouping.normalized(materials:materials,anchors:anchors)
        for (index, segment) in segments.sorted(by: { $0.start < $1.start }).enumerated() {
            lines.append("\(index + 1). \(segment.text)")
            for binding in Association.bindings(for: segment, anchors: selections) {
                let refs = binding.materialIDs.isEmpty ? "无明确素材" : binding.materialIDs.joined(separator:"、")
                lines.append("   “\(binding.phrase)”\(binding.certain ? "对应" : "待确认，候选")：\(refs)\(binding.certain ? "" : "；" + binding.explanation)")
            }
        }
        lines += ["", "素材索引"]
        for item in materials {
            lines.append("[\(item.id)] \(item.kind) · \(item.label)")
            lines.append("来源：\(item.source)")
            lines.append("内容：\(item.content)")
            if let path = item.localPath { lines.append("已保存副本：assets/\(URL(fileURLWithPath: path).lastPathComponent)") }
            if item.availability != "original" { lines.append("获取状态：\(item.availability == "excerpt" ? "视觉片段，非图片原件" : "仅来源，尚无原件")") }
        }
        if !gaps.isEmpty { lines += ["", "采集缺口／需要核对"] + Array(Set(gaps)).sorted().map { "- " + $0 } }
        lines += ["", "说明：本稿保留原话与证据关联；复杂更正、跨历史指代仍需核对。"]
        return lines.joined(separator:"\n")
    }
}

public struct WorkBarrier: Sendable {
    public var pending: [UUID: Double] = [:]
    public init() {}
    public mutating func begin(at time: Double) -> UUID { let id = UUID(); pending[id] = time; return id }
    public mutating func settle(_ id: UUID) { pending.removeValue(forKey: id) }
    public func ready(through cutoff: Double) -> Bool { !pending.values.contains { $0 <= cutoff } }
}

public enum CaptureOrdering {
    public static func accepts(time: Double, cutoff: Double?, collecting: Bool, finalizing: Bool) -> Bool {
        collecting || (finalizing && cutoff.map { time <= $0 } == true)
    }
    public static func sortedIntervals(_ input: [Anchor]) -> [Anchor] {
        var output = input.sorted { $0.start < $1.start }
        for index in output.indices.dropLast() {
            if (output[index].end ?? .infinity) > output[index + 1].start {
                output[index].end = output[index + 1].start
                output[index].endUncertainty = output[index + 1].uncertainty
            }
        }
        return output
    }
}

/// A selection change is bounded by the preceding read and the completed new read.
/// Certainty begins at the upper bound, rather than an arbitrary delay afterward.
public struct SelectionObservationWindow {
    private var previousReadStart: Double?
    public init() {}
    public mutating func reset() { previousReadStart = nil }
    public mutating func observe(start: Double, end: Double) -> (time: Double, uncertainty: Double) {
        let lower = previousReadStart ?? start
        previousReadStart = start
        return ((lower + end) / 2, max(0.005, (end - lower) / 2 + 0.005))
    }
}

public struct AudioSpan: Codable, Sendable {
    public var audioStart: Double
    public var audioEnd: Double
    public var hostStart: Double
    public init(audioStart: Double, audioEnd: Double, hostStart: Double) {
        self.audioStart = audioStart; self.audioEnd = audioEnd; self.hostStart = hostStart
    }
}

/// Map file-based word times back to the actual microphone host clock, including gaps.
public enum RecordingTimeline {
    public static func hostTime(_ audioTime: Double, spans: [AudioSpan], fallbackOrigin: Double, endBoundary: Bool = false) -> Double {
        guard !spans.isEmpty else { return fallbackOrigin + audioTime }
        var low = 0, high = spans.count
        while low < high {
            let middle = (low + high) / 2
            let followsBoundary = endBoundary ? spans[middle].audioStart < audioTime - 1e-8 : spans[middle].audioStart <= audioTime + 1e-8
            if followsBoundary { low = middle + 1 } else { high = middle }
        }
        let span = spans[max(0, low - 1)]
        return span.hostStart + audioTime - span.audioStart
    }
}

/// Result chunks are decoder delivery units, not separate user requests.
public enum TranscriptAssembly {
    public static func coalesced(_ input: [SpokenSegment]) -> [SpokenSegment] {
        var output: [SpokenSegment] = []
        for segment in input.sorted(by: { $0.start < $1.start }) {
            if let last = output.last, segment.start - last.end <= 0.45 {
                let index = output.count - 1
                output[index].text += segment.text
                output[index].end = max(last.end, segment.end)
                output[index].words += segment.words
            } else { output.append(segment) }
        }
        return output
    }
}
