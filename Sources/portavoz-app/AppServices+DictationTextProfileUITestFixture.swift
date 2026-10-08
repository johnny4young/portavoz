import Foundation

/// Only the disposable app's initial chooser directory is replaced, never its selection or reader.
enum DictationProfilePickerUITestFixture {
    static func directory(
        arguments: [String], environment: [String: String], usesTemporaryStore: Bool
    ) -> URL? {
        guard usesTemporaryStore, arguments.contains("-use-temp-store"),
              arguments.contains("-seed-dictation-profile-picker"),
              let root = environment["TMPDIR"], root.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("dictation-profile-applications", isDirectory: true)
    }
}
