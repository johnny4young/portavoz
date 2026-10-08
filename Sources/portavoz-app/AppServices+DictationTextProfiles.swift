import AppKit
import UniformTypeIdentifiers

extension AppServices {
    /// Explicit local file selection only. The application is neither launched nor registered.
    func selectDictationProfileApplication() async {
        guard dictationTextSettings.beginApplicationSelection() else { return }
        defer { dictationTextSettings.finishApplicationSelection() }
        guard let window = NSApp.keyWindow else {
            dictationTextSettings.reportSelectionError(.unavailableWindow)
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let directory = DictationProfilePickerUITestFixture.directory(
            arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment,
            usesTemporaryStore: usesTemporaryMeetingStore) {
            panel.directoryURL = directory
        }
        panel.message = L10n.text(
            "Choose an application for its dictation text mode. Only its bundle identifier is saved.")
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
        guard let identifier = Bundle(url: url)?.bundleIdentifier,
              DictationTextPreferences.isValidBundleIdentifier(identifier) else {
            dictationTextSettings.reportSelectionError()
            return
        }
        // Choosing an application that already has a profile keeps its saved mode.
        let existing = dictationTextSettings.profiles.first { $0.bundleIdentifier == identifier }?.mode
        dictationTextSettings.setProfile(
            bundleIdentifier: identifier, mode: existing ?? dictationTextSettings.globalMode)
    }
}
