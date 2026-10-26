import Foundation

/// Spoken corrections of the last insertion; off by default.
enum DictationCorrections {
    static let defaultsKey = "dictationCorrectionCommands"

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }
}
