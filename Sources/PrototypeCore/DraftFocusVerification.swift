import Foundation

/// Focus only a verified stable composer; never chase a changed window or draft.
public struct DraftFocusVerification {
    public enum Status { case requestFocus, waiting, verified, changed }
    private var requested = false
    private var focusedSamples = 0
    private var stopped = false
    public init() {}
    public mutating func observe(windowStable: Bool, draftAllowed: Bool, focused: Bool) -> Status {
        guard !stopped, windowStable, draftAllowed else { stopped = true; return .changed }
        if focused {
            focusedSamples += 1
            return focusedSamples >= 2 ? .verified : .waiting
        }
        focusedSamples = 0
        if !requested { requested = true; return .requestFocus }
        return .waiting
    }
}
