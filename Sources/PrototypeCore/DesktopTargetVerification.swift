import Foundation

/// A title, a sidebar match or a remembered deep link is not live identity proof.
/// Only a document URL read from the focused target window may enter this check.
public enum DesktopTargetVerification {
    public static func allowsBoundDraft(bundleID: String, liveLink: String?, expectedThreadID: String, fieldCount: Int, currentValue: String) -> Bool {
        UUID(uuidString:expectedThreadID) != nil && matches(bundleID:bundleID,documentURL:liveLink,expectedThreadID:expectedThreadID) && fieldCount == 1 && currentValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
    }
    /// Controlled test only: a human must verify the actual destination. Title is not authentication.
    public static func allowsReviewedDraft(bundleID: String, windowTitle: String, expectedThreadID: String, fieldCount: Int, currentValue: String, humanConfirmed: Bool) -> Bool {
        humanConfirmed && allowsSyntheticDraft(bundleID:bundleID,windowTitle:windowTitle,expectedThreadID:expectedThreadID,fieldCount:fieldCount,currentValue:currentValue)
    }
    /// For a non-sensitive synthetic draft only; never authorizes sending real user content.
    public static func allowsSyntheticDraft(bundleID: String, windowTitle: String, expectedThreadID: String, fieldCount: Int, currentValue: String) -> Bool {
        bundleID == "com.openai.codex" && UUID(uuidString:expectedThreadID) != nil &&
            windowTitle == "连续表达联通测试 · " + expectedThreadID && fieldCount == 1 &&
            currentValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
    }
    public static func matches(bundleID: String, documentURL: String?, expectedThreadID: String) -> Bool {
        guard bundleID == "com.openai.codex", !expectedThreadID.isEmpty,
              let documentURL, let url = URLComponents(string:documentURL) else { return false }
        return url.scheme == "codex" && url.host == "threads" && url.path == "/" + expectedThreadID &&
            url.query == nil && url.fragment == nil && url.user == nil && url.password == nil && url.port == nil
    }
}

public enum AXDiagnosticEvidence {
    public static func safeLabel(_ value: String, targetTitle: String) -> String {
        let labels: Set<String> = ["发送","发送消息","停止","输入消息","消息","提示词","Send","Send message","Stop","Message","Message Codex","Message ChatGPT","Ask anything","New chat"]
        return value == targetTitle || labels.contains(value) ? value : "[已隐藏 \(value.count) 字符]"
    }
    public static func snapshotMatches(urls: [String], webAreaCount: Int, complete: Bool, expectedThreadID: String) -> Bool {
        complete && webAreaCount == 1 && urls.count == 1 &&
            DesktopTargetVerification.matches(bundleID:"com.openai.codex",documentURL:urls.first,expectedThreadID:expectedThreadID)
    }
}

/// Exact echo needs two consecutive observations; losing identity permanently stops this attempt.
public struct DraftReadbackVerification {
    public enum Status: Equatable { case waiting, verified, targetChanged }
    private let expected: Data
    private var matches = 0
    private var stopped = false
    public init(expected: String) { self.expected = Data(expected.utf8) }
    public mutating func observe(echo: String?, identityStable: Bool) -> Status {
        if !identityStable { stopped = true }
        if stopped { return .targetChanged }
        matches = echo.map { Data($0.utf8) == expected } == true ? matches + 1 : 0
        return matches >= 2 ? .verified : .waiting
    }
}
