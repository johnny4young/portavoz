import AppKit
import ApplicationKit
import SwiftUI

/// Settings keeps only the native destination picker and declarative state.
/// Snapshot, rendering, naming, partial failure, and publication live behind
/// the process-scoped application workflow.
struct BackupSection: View {
    @Environment(AppServices.self) private var services

    private var model: LibraryMarkdownBackupModel {
        services.libraryMarkdownBackup
    }

    var body: some View {
        Section("Your data") {
            Button {
                chooseFolderAndExport()
            } label: {
                Label("Export all meetings (Markdown)…", systemImage: "externaldrive")
            }
            .disabled(model.isRunning)
            .accessibilityIdentifier("settings-export-all-button")

            progressView
            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-backup-status")
            }
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Writes one Markdown file per meeting — summary, action items and full transcript — into a folder you choose. Plain files you can read, grep and back up without Portavoz."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var progressView: some View {
        if case .running(let event) = model.phase {
            switch event {
            case .preparing:
                ProgressView("Exporting…")
                    .controlSize(.small)
                    .accessibilityIdentifier("settings-backup-progress")
            case .exporting(let progress):
                ProgressView(
                    value: Double(progress.completedMeetings),
                    total: Double(max(1, progress.totalMeetings))
                ) {
                    Text(L10n.format(
                        "Exporting… %d of %d",
                        progress.completedMeetings,
                        progress.totalMeetings))
                }
                .controlSize(.small)
                .accessibilityIdentifier("settings-backup-progress")
            }
        }
    }

    private var statusText: String? {
        switch model.phase {
        case .idle, .running:
            nil
        case .completed(let result)
            where result.failures.isEmpty && result.exportedCount == 1:
            L10n.text("1 meeting exported.")
        case .completed(let result) where result.failures.isEmpty:
            L10n.format("%d meetings exported.", result.exportedCount)
        case .completed(let result):
            L10n.format(
                "%d exported · %d could not be exported.",
                result.exportedCount,
                result.failures.count)
        case .failed(.libraryUnavailable):
            L10n.text("Couldn’t read the library. Your meetings were not changed.")
        case .failed(.destinationUnavailable):
            L10n.text("Couldn’t use that folder. Choose another folder and try again.")
        case .failed(.unexpected):
            L10n.text("Couldn’t export the library. Your meetings were not changed.")
        }
    }

    private func chooseFolderAndExport() {
        guard !model.isRunning, let folder = chooseDestination() else { return }
        Task { await model.export(to: folder) }
    }

    @MainActor
    private func chooseDestination() -> URL? {
        let process = ProcessInfo.processInfo
        if process.arguments.contains("-use-temp-store"),
           let path = process.environment["PORTAVOZ_UI_TEST_BACKUP_FOLDER"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("Export here")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
