import Foundation

public struct DesktopConversation: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let cwd: String
    public let updatedAt: Double
}

/// Track only the copy command's link, including when focus changes immediately after copying.
public struct CopiedLinkObservation {
    public enum Result: Equatable { case waiting, ready(String), targetChanged }
    private let initialChangeCount: Int
    private var ownCount: Int?
    private var ownText: String?
    private var stopped = false
    public init(initialChangeCount: Int) { self.initialChangeCount = initialChangeCount }
    public mutating func observe(changeCount: Int, text: String?, windowStable: Bool) -> Result {
        if stopped { return .targetChanged }
        if changeCount != initialChangeCount, let text, text.hasPrefix("codex://threads/") {
            ownCount = changeCount; ownText = text
        }
        guard windowStable else { stopped = true; return .targetChanged }
        if let ownText { return .ready(ownText) }
        return .waiting
    }
    public func canRestore(changeCount: Int, text: String?) -> Bool {
        guard let ownCount, let ownText, changeCount == ownCount, let text else { return false }
        return text.utf8.elementsEqual(ownText.utf8)
    }
}
