import Foundation

/// Only a verified, unchanged composer and one explicit idle Send control authorize one submission.
public struct DesktopSendAuthorization {
    /// The submit shortcut can exit a code block instead of submitting. Require
    /// a plain opening paragraph so the adapter can place the caret at its start.
    public static func allowsShortcutStart(text: String) -> Bool {
        guard let line = text.components(separatedBy:.newlines).first(where:{ !$0.trimmingCharacters(in:.whitespaces).isEmpty }) else { return false }
        var indentation = 0
        for character in line {
            if character == " " { indentation += 1 }
            else if character == "\t" { indentation += 4-(indentation % 4) }
            else { break }
            if indentation >= 4 { return false }
        }
        return !line.contains("```") && !line.contains("~~~")
    }
    public enum ComposerDisposition { case writeEmpty, reuseExact, reject }
    public static func composerDisposition(current: String, approved: String, allowReuse: Bool) -> ComposerDisposition {
        if current.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return .writeEmpty }
        if allowReuse && !approved.isEmpty && current.utf8.elementsEqual(approved.utf8) { return .reuseExact }
        return .reject
    }
    private var consumed = false
    public init() {}
    public static func isSendButton(role: String, label: String) -> Bool {
        role == "AXButton" && ["发送","发送消息","傳送","傳送訊息","Send","Send message"].contains(label)
    }
    /// Enumerating AX action names is not a submission. Invoke the verified
    /// submit action once; acceptance still requires an independent receipt.
    public mutating func performOnce(identityMatched: Bool, exactEcho: Bool, focusStable: Bool, sendButtonCount: Int, buttonEnabled: Bool, responseActive: Bool, action: () -> Int32) -> Int32? {
        guard consume(identityMatched:identityMatched,exactEcho:exactEcho,focusStable:focusStable,sendButtonCount:sendButtonCount,buttonEnabled:buttonEnabled,responseActive:responseActive) else { return nil }
        return action()
    }
    public mutating func consume(identityMatched: Bool, exactEcho: Bool, focusStable: Bool, sendButtonCount: Int, buttonEnabled: Bool, responseActive: Bool) -> Bool {
        guard !consumed, identityMatched, exactEcho, focusStable, sendButtonCount == 1, buttonEnabled, !responseActive else { return false }
        consumed = true; return true
    }
}
