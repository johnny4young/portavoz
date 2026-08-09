import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppLaunchRecoveryView: View {
    let model: AppLaunchModel

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Your library couldn't be opened")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("launch-recovery-title")
                    .accessibilityLabel(Text("Your library couldn't be opened"))
                Text(
                    """
                    Portavoz stopped before starting background work. \
                    Your original library has not been changed or deleted.
                    """)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case let .databaseUnavailable(failure) = model.phase {
                Label {
                    Text(failure.databaseFilePresent
                         ? LocalizedStringKey("Database file found")
                         : LocalizedStringKey("Database file not found"))
                } icon: {
                    Image(systemName: failure.databaseFilePresent
                          ? "checkmark.circle"
                          : "questionmark.circle")
                }
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("launch-recovery-file-evidence")
            }

            HStack(spacing: 10) {
                Button("Try again") {
                    Task { await model.retry() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("launch-recovery-retry")
                .disabled(model.hasOperationInProgress)

                Button("Save recovery copy…") {
                    Task {
                        guard let destination = await AppLaunchRecoveryPanels
                            .chooseRecoveryDirectory()
                        else { return }
                        await model.saveRecoveryCopy(to: destination)
                    }
                }
                .accessibilityIdentifier("launch-recovery-save-copy")
                .disabled(
                    model.hasOperationInProgress || !databaseFilePresent)

                Button("Export launch diagnostics…") {
                    Task {
                        guard let destination = await AppLaunchRecoveryPanels
                            .chooseDiagnosticsDestination()
                        else { return }
                        await model.exportDiagnostics(to: destination)
                    }
                }
                .accessibilityIdentifier("launch-recovery-export-diagnostics")
                .disabled(model.hasOperationInProgress)
            }

            VStack(spacing: 5) {
                artifactStatus(
                    model.recoveryCopyState,
                    working: "Saving recovery copy…",
                    succeeded: "Recovery copy saved",
                    failed: "The recovery copy couldn't be saved",
                    identifier: "launch-recovery-copy-status")
                artifactStatus(
                    model.diagnosticsState,
                    working: "Exporting launch diagnostics…",
                    succeeded: "Launch diagnostics saved",
                    failed: "The launch diagnostics couldn't be saved",
                    identifier: "launch-recovery-diagnostics-status")
            }
            .frame(minHeight: 42, alignment: .top)

            Text(
                """
                A recovery copy is created by reading the failed library without \
                modifying it, verified before publication, and never overwrites an \
                existing copy.
                """)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var databaseFilePresent: Bool {
        guard case let .databaseUnavailable(failure) = model.phase else {
            return false
        }
        return failure.databaseFilePresent
    }

    @ViewBuilder
    private func artifactStatus(
        _ state: AppLaunchModel.ArtifactState,
        working: LocalizedStringKey,
        succeeded: LocalizedStringKey,
        failed: LocalizedStringKey,
        identifier: String
    ) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .working:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(working)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(Text(working))
        case .succeeded:
            Label(succeeded, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(Text(succeeded))
        case .failed:
            Label(failed, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(Text(failed))
        }
    }
}

struct AppLaunchOpeningView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Opening your library…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("launch-recovery-opening")
    }
}

@MainActor
private enum AppLaunchRecoveryPanels {
    static func chooseRecoveryDirectory() async -> URL? {
        if let automated = automatedURL(
            environmentKey: "PORTAVOZ_UI_TEST_DATABASE_RECOVERY_DIRECTORY") {
            return automated
        }

        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a folder for the recovery copy")
        panel.prompt = String(localized: "Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let response = await response(from: panel)
        return response == .OK ? panel.url : nil
    }

    static func chooseDiagnosticsDestination() async -> URL? {
        if let automated = automatedURL(
            environmentKey: "PORTAVOZ_UI_TEST_LAUNCH_DIAGNOSTICS_PATH") {
            return automated
        }

        let panel = NSSavePanel()
        panel.title = String(localized: "Export launch diagnostics")
        panel.prompt = String(localized: "Export")
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Portavoz Launch Diagnostics.json"
        let response = await response(from: panel)
        return response == .OK ? panel.url : nil
    }

    private static func automatedURL(environmentKey: String) -> URL? {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("-use-temp-store"),
              let path = process.environment[environmentKey],
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func response(from panel: NSSavePanel) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response)
            }
        }
    }
}
