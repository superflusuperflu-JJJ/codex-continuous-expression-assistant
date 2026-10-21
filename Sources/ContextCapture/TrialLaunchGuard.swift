import Foundation

enum TrialLaunchGuard {
    static func installationRequired(path: String, volumeReadOnly: Bool = false) -> Bool {
        volumeReadOnly || path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }
}
