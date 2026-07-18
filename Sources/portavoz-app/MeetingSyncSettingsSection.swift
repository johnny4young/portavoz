import IntegrationsKit
import SwiftUI

/// Truthful control surface for D97's opt-in text-first CloudKit adapter.
/// Every destructive or broadening action remains separate and explicit.
struct MeetingSyncSettingsSection: View {
    @Environment(AppServices.self) private var services
    @State private var confirmExistingLibrary = false
    @State private var confirmRemoveDevice = false

    private var model: MeetingSyncModel { services.meetingSync }
    private var status: CloudMeetingSyncStatus { model.status }

    var body: some View {
        Group {
            Section("iCloud sync") {
                statusCard
                Text(
                    // One-line UI help text.
                    // swiftlint:disable:next line_length
                    "Encrypted meeting text and portable metadata sync through your private iCloud database. Audio, local file paths, voiceprints, secrets, and embeddings never sync."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Controls") {
                controls
                if status.isEnabled, status.initialSeedState == .notRequested {
                    Button {
                        confirmExistingLibrary = true
                    } label: {
                        Label("Include existing library…", systemImage: "books.vertical")
                    }
                    .accessibilityIdentifier("settings-sync-seed")
                    .disabled(model.isBusy)
                }
            }

            if status.isEnabled || status.failure == .transportStateUnavailable {
                Section("This Mac") {
                    Button(role: .destructive) {
                        confirmRemoveDevice = true
                    } label: {
                        Label("Remove this Mac from sync…", systemImage: "trash")
                    }
                    .accessibilityIdentifier("settings-sync-remove")
                    .disabled(model.isBusy)
                    Text(
                        // One-line UI help text.
                        // swiftlint:disable:next line_length
                        "This clears only this Mac's protected sync queue and consent. Local meetings stay here, and encrypted records already in iCloud are not deleted."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog(
            "Include existing library?",
            isPresented: $confirmExistingLibrary,
            titleVisibility: .visible
        ) {
            Button("Include existing library") {
                run(.includeExistingLibrary)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Future changes already sync. This one-time action also encrypts and queues meetings that existed before sync was enabled; audio is never included."
            )
        }
        .confirmationDialog(
            "Remove this Mac from sync?",
            isPresented: $confirmRemoveDevice,
            titleVisibility: .visible
        ) {
            Button("Remove this Mac", role: .destructive) {
                run(.removeThisDevice)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your local meetings and recordings will stay on this Mac.")
        }
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusIcon)
                .font(.title2)
                .foregroundStyle(statusTint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(statusTitle)
                        .font(.headline)
                        .accessibilityIdentifier("settings-sync-status")
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if status.isEnabled {
                    Text(progressText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var controls: some View {
        if !status.isEnabled {
            Button {
                run(.enable)
            } label: {
                Label("Enable iCloud sync", systemImage: "icloud.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("settings-sync-enable")
            .disabled(model.isBusy || status.failure == .transportStateUnavailable)
        } else {
            HStack {
                Button {
                    run(.synchronize)
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("settings-sync-now")
                .disabled(model.isBusy || status.accountStatus != .available)

                if status.phase == .failed || status.phase == .retrying {
                    Button("Retry now") { run(.retry) }
                        .accessibilityIdentifier("settings-sync-retry")
                        .disabled(model.isBusy)
                }

                Spacer()
                Button("Pause on this Mac") { run(.pause) }
                    .accessibilityIdentifier("settings-sync-pause")
                    .disabled(model.isBusy)
            }
        }
    }

    private var statusTitle: String {
        switch status.phase {
        case .localOnly: L10n.text("Local only")
        case .pending: L10n.text("Syncing")
        case .synchronized: L10n.text("Up to date")
        case .paused: L10n.text("Paused")
        case .retrying: L10n.text("Waiting to retry")
        case .failed: L10n.text("Needs attention")
        }
    }

    private var statusDetail: String {
        if let failure = status.failure {
            return failureDetail(failure)
        }
        if !status.isEnabled {
            return L10n.text("Off. Portavoz has not contacted iCloud for meeting sync.")
        }
        switch status.accountStatus {
        case .available:
            return L10n.text("Connected to your private iCloud database.")
        case .signedOut:
            return L10n.text("Sign in to iCloud on this Mac to continue.")
        case .restricted:
            return L10n.text("iCloud access is restricted on this Mac.")
        case .temporarilyUnavailable:
            return L10n.text("iCloud is temporarily unavailable. Portavoz will retry.")
        case .unknown:
            return L10n.text("Waiting for iCloud account status.")
        }
    }

    private func failureDetail(_ failure: CloudMeetingSyncLifecycleFailure) -> String {
        switch failure {
        case .capabilityUnavailable:
            return L10n.text(
                // swiftlint:disable:next line_length
                "This build is not provisioned for iCloud sync. Install a signed Portavoz release with CloudKit enabled.")
        case .accountCheckFailed:
            return L10n.text("Portavoz could not check the iCloud account. Try again.")
        case .accountIdentityUnavailable:
            return L10n.text("The current iCloud account could not be identified.")
        case .transportCreationFailed:
            return L10n.text("Portavoz could not prepare the private iCloud transport.")
        case .synchronizationFailed:
            return L10n.text("The last sync did not finish. Your local data is safe.")
        case .journalUnavailable:
            return L10n.text("The local change journal could not be read.")
        case .transportStateUnavailable:
            return L10n.text(
                "Protected sync state is damaged. Remove this Mac from sync to reset only that state.")
        }
    }

    private var progressText: String {
        L10n.format(
            "%d local · %d queued · %d retrying · %d failed",
            status.progress.pendingLocalChanges,
            status.progress.queuedTransfers,
            status.progress.retryingTransfers,
            status.progress.failedTransfers)
    }

    private var statusIcon: String {
        switch status.phase {
        case .localOnly: "externaldrive"
        case .pending: "icloud.and.arrow.up"
        case .synchronized: "checkmark.icloud"
        case .paused: "pause.circle"
        case .retrying: "clock.arrow.circlepath"
        case .failed: "exclamationmark.icloud"
        }
    }

    private var statusTint: Color {
        switch status.phase {
        case .synchronized: .green
        case .failed: .orange
        default: .accentColor
        }
    }

    private func run(_ action: MeetingSyncModel.Action) {
        Task { await model.send(action) }
    }
}
