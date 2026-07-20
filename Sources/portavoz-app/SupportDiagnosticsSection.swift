import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Explicit, local-only support export. Generation is isolated from file
/// selection so canceling the panel writes nothing and no network capability
/// ever observes the report.
struct SupportDiagnosticsSection: View {
    @Environment(AppServices.self) private var services
    @State private var status: String?
    @State private var exporting = false

    var body: some View {
        Section("Support diagnostics") {
            Button {
                export()
            } label: {
                Label("Export redacted support file…", systemImage: "stethoscope")
            }
            .disabled(exporting)
            .accessibilityIdentifier("settings-export-diagnostics")

            if exporting {
                ProgressView("Preparing support file…")
                    .controlSize(.small)
            }
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-diagnostics-status")
            }
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Includes app, macOS, model, processing, provenance, and privacy-receipt status. Never includes meeting text, generated output, prompts, secrets, full URLs, or file paths. Nothing is sent automatically."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func export() {
        guard !exporting else { return }
        exporting = true
        status = nil
        Task {
            do {
                let data = try await services.exportSupportDiagnostics()
                guard let destination = chooseDestination() else {
                    exporting = false
                    return
                }
                try data.write(to: destination, options: .atomic)
                status = L10n.text("Support file saved — no meeting content included.")
            } catch {
                status = L10n.text("Could not create the support file. Try again.")
            }
            exporting = false
        }
    }

    @MainActor
    private func chooseDestination() -> URL? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-use-temp-store"),
           let path = ProcessInfo.processInfo.environment[
               "PORTAVOZ_UI_TEST_DIAGNOSTICS_PATH"] {
            return URL(fileURLWithPath: path)
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "portavoz-support.json"
        panel.prompt = L10n.text("Save support file")
        panel.message = L10n.text(
            "The file is redacted and stays on your Mac unless you choose to share it.")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
