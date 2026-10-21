import Foundation

/// Derive one intent-level selection from a drag. Original anchors remain intact.
public enum SelectionGrouping {
    public static func normalized(materials: [Material], anchors: [Anchor]) -> [Anchor] {
        let byID = Dictionary(uniqueKeysWithValues:materials.map { ($0.id,$0) })
        let ordered = anchors.sorted { $0.start < $1.start }
        func text(_ anchor: Anchor) -> String? {
            let items = anchor.materialIDs.compactMap { byID[$0] }
            guard items.count == anchor.materialIDs.count,
                  items.allSatisfy({ ["文字","链接"].contains($0.kind) }),
                  items.filter({$0.kind == "文字"}).count == 1 else { return nil }
            return items.first(where:{$0.kind == "文字"})!.content.trimmingCharacters(in:.whitespacesAndNewlines)
        }
        func completed(_ first: Anchor, _ final: Anchor) -> Anchor {
            var result = final
            // Include the observed drag onset, rather than requiring the user to
            // finish selecting before pronouncing the referent. Competing anchors
            // still overlap this interval and therefore remain ambiguous.
            result.start = min(first.start, first.selectionStart ?? first.start) - first.uncertainty
            result.uncertainty = 0
            return result
        }
        var output: [Anchor] = [], index = 0
        while index < ordered.count {
            let first = ordered[index]
            guard let initial = text(first), !initial.isEmpty else { output.append(first); index += 1; continue }
            var end = index
            if let selectionID = first.selectionID {
                while end + 1 < ordered.count && ordered[end+1].source == first.source && ordered[end+1].selectionID == selectionID && text(ordered[end+1]) != nil {
                    end += 1
                }
                if ordered[end].selectionComplete == true {
                    output.append(completed(first,ordered[end])); index = end + 1; continue
                }
                // An unfinished gesture must not silently become a completed one.
                output.append(contentsOf:ordered[index...end]); index = end + 1; continue
            }
            // Backward-compatible reconstruction for existing recordings without
            // pointer metadata: brief, strictly nested, same-direction snapshots.
            var direction = 0, prefix = true, suffix = true
            while end + 1 < ordered.count {
                let previous = ordered[end], next = ordered[end+1]
                guard next.selectionID == nil, next.source == first.source,
                      let previousEnd = previous.end, previousEnd - previous.start <= 0.7,
                      next.start - previousEnd >= -0.001, next.start - previousEnd <= 0.15,
                      next.start - first.start <= 2,
                      let before = text(previous), let after = text(next), !after.isEmpty, before != after else { break }
                let nextDirection = after.count > before.count ? 1 : -1
                guard direction == 0 || direction == nextDirection else { break }
                let smaller = nextDirection == 1 ? before : after, larger = nextDirection == 1 ? after : before
                let nextPrefix = prefix && larger.hasPrefix(smaller), nextSuffix = suffix && larger.hasSuffix(smaller)
                guard nextPrefix || nextSuffix else { break }
                direction = nextDirection; prefix = nextPrefix; suffix = nextSuffix; end += 1
            }
            if end - index >= 2 && (ordered[end].end.map { $0 - ordered[end].start >= 0.25 } ?? true) {
                output.append(completed(first,ordered[end])); index = end + 1
            } else { output.append(first); index += 1 }
        }
        return output
    }
}
