import AppKit
import ApplicationKit
import Foundation
import UniformTypeIdentifiers

extension AppServices: SettingsTransferClient {
    private var portableSettingsStore: AppPortableSettingsStore {
        AppPortableSettingsStore(defaults: .standard, temporary: usesTemporaryMeetingStore)
    }

    func portableSettingsSnapshot() throws -> [PortableSettingsKey: PortableSettingsValue] {
        try portableSettingsStore.snapshot()
    }

    func applyPortableSettings(_ review: PortableSettingsReview) throws -> Int {
        let recordingBusy: Bool = switch recording.phase {
        case .preparing, .recording, .processing: true
        case .idle, .done, .failed: false
        }
        return try portableSettingsStore.apply(
            review, captureActive: recordingBusy || dictation.phase == .listening)
    }

    func selectSettingsFile(_ operation: SettingsTransferFileOperation) -> URL? {
        if usesTemporaryMeetingStore {
            return SettingsTransferUITestFileSelection.url(
                for: operation, arguments: ProcessInfo.processInfo.arguments,
                environment: ProcessInfo.processInfo.environment)
        }
        switch operation {
        case .exportFile:
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "portavoz-settings.json"
            panel.message = L10n.text(
                "This file includes vocabulary and replacements. Share it only with people you trust.")
            return panel.runModal() == .OK ? panel.url : nil
        case .importFile:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.message = L10n.text(
                "Review portable preferences before applying them. No permissions are transferred.")
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    func readSettingsFile(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) { try PortableSettingsFile.read(url) }.value
    }

    func writeSettingsFile(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .utility) { try PortableSettingsFile.write(data, to: url) }.value
    }
}

enum SettingsTransferUITestFileSelection {
    static func url(
        for operation: SettingsTransferFileOperation,
        arguments: [String], environment: [String: String]
    ) -> URL? {
        guard arguments.contains("-use-temp-store"), arguments.contains("-seed-settings-transfer") else { return nil }
        let key = operation == .exportFile ? "PORTAVOZ_UI_TEST_SETTINGS_EXPORT" : "PORTAVOZ_UI_TEST_SETTINGS_IMPORT"
        guard let path = environment[key], path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }
}
