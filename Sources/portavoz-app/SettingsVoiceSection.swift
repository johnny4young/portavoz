import SwiftUI

/// Settings-owned presentation for the user's encrypted local voice identity.
/// Storage, capture, and model work stay behind the AppServices application
/// capability; this view owns only one visible load/enroll/delete lifecycle.
struct SettingsVoiceSection: View {
    @Environment(AppServices.self) private var services
    @State private var enrollmentDate: Date?
    @State private var enrolling = false
    @State private var message: String?
    @State private var loadError: String?

    var body: some View {
        Section("My voice") {
            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("settings-voice-storage-error")
                HStack {
                    Button("Try again") {
                        Task { await loadStatus() }
                    }
                    .accessibilityIdentifier("settings-voice-storage-retry")
                    Button("Delete stored voice identity", role: .destructive) {
                        Task { await deleteVoice() }
                    }
                    .accessibilityIdentifier("settings-voice-storage-reset")
                }
            } else if let enrollmentDate {
                LabeledContent(
                    "Enrolled voice",
                    value: enrollmentDate.formatted(date: .abbreviated, time: .shortened))
                Button("Delete my voice", role: .destructive) {
                    Task { await deleteVoice() }
                }
                .accessibilityIdentifier("settings-voice-delete")
            } else if enrolling {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Recording 12 seconds — speak naturally…")
                }
            } else {
                Button {
                    Task { await enroll() }
                } label: {
                    Label("Enroll my voice (12 s)", systemImage: "person.wave.2")
                }
                .accessibilityIdentifier("settings-voice-enroll")
            }
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "With your voice enrolled, Portavoz also recognizes you when you arrive through system audio (hybrid meetings). Only an encrypted numeric fingerprint is stored on this device — never audio, never cloud data; delete it with one click."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await loadStatus() }
    }

    private func enroll() async {
        enrolling = true
        defer { enrolling = false }
        do {
            let voiceprint = try await services.recordAndEnrollLocalVoice(
                seconds: 12,
                mode: .echoCancelled)
            enrollmentDate = voiceprint.createdAt
            loadError = nil
            message = L10n.text(
                "Done: your interventions will be tagged as “Me” on any channel.")
        } catch {
            message = L10n.format(
                "Could not enroll: %@",
                UseCaseErrorMessages.describe(error))
        }
    }

    private func deleteVoice() async {
        do {
            try await services.deleteLocalVoiceIdentity()
            enrollmentDate = nil
            loadError = nil
            message = L10n.text("Voiceprint and key deleted.")
        } catch {
            message = L10n.text(
                "Could not delete your voice. Nothing was reported as deleted; try again.")
        }
    }

    private func loadStatus() async {
        do {
            enrollmentDate = try await services.localVoiceIdentityStatus()?.createdAt
            loadError = nil
        } catch {
            enrollmentDate = nil
            loadError = L10n.text(
                "Your stored voice identity could not be opened. Nothing was changed.")
        }
    }
}
