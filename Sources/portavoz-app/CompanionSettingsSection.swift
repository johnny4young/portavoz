import Foundation
import SwiftUI

/// Apuntador in Settings: one status with three values, one cause line, and
/// short captions with the explanation behind "How it works".
struct CompanionSettingsSection: View {
    let capability: FoundationModelsCapability
    let detectorAvailable: Bool
    /// A validated BYOK provider (client would build) answers general
    /// knowledge questions even where Apple Intelligence cannot run.
    let providerAnswersAvailable: Bool
    @Binding var companionEnabled: Bool
    @Binding var companionUserName: String
    @Binding var mirrorAfterMeeting: Bool

    /// Ready · Questions only · Unavailable, never a green check over a failure.
    private enum Readiness {
        case ready
        case readyThroughProvider
        case questionsOnly(cause: String)
        case unavailable
    }

    private var readiness: Readiness {
        guard detectorAvailable else { return .unavailable }
        switch capability {
        case .available:
            return .ready
        case .requiresMacOS26 where providerAnswersAvailable,
             .unavailable where providerAnswersAvailable:
            return .readyThroughProvider
        case .requiresMacOS26:
            return .questionsOnly(cause: L10n.text(
                // One-line UI explanation.
                // swiftlint:disable:next line_length
                "On macOS Sequoia, cards show the question only. Generated answers need macOS Tahoe with Apple Intelligence, or a provider you enable."))
        case .unavailable(let reason):
            return .questionsOnly(cause: L10n.format(
                "Generated answers are unavailable: %@. Cards show the question only.", reason))
        }
    }

    var body: some View {
        Section("Apuntador") {
            capabilityStatus
            Toggle("Enable Apuntador for recordings", isOn: $companionEnabled)
                .accessibilityIdentifier("settings-apuntador-enabled")
                .disabled(!detectorAvailable)
            HStack(spacing: 10) {
                Text("Detects questions during a recording and suggests answers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HowItWorksLink(
                    text: L10n.text(
                        // swiftlint:disable:next line_length
                        "Apuntador listens for questions in the live captions and shows each one as a card. With an answer engine (Apple Intelligence on macOS Tahoe, or a provider you enable) it drafts an answer from the meeting; without one, cards show the question only. Nothing is sent anywhere unless you enabled a provider."),
                    identifier: "settings-apuntador-how-it-works")
            }

            TextField(
                "Your name in meetings",
                text: $companionUserName,
                prompt: Text(NSFullUserName())
            )
            .autocorrectionDisabled()
            Text(L10n.format(
                "Cards addressed to “%@” are marked as asked to you.",
                companionUserName.isEmpty ? NSFullUserName() : companionUserName))
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Your talk time after each meeting", isOn: $mirrorAfterMeeting)
                .accessibilityIdentifier("settings-mirror-after-meeting")
            Text("After meetings of five minutes or more, next to your average.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var capabilityStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(statusTitle, systemImage: statusSymbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(statusTint)
                .accessibilityIdentifier("settings-apuntador-status")
            Text(statusCause)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-apuntador-status-cause")
        }
    }

    private var statusTitle: String {
        switch readiness {
        case .ready, .readyThroughProvider: L10n.text("Apuntador: ready")
        case .questionsOnly: L10n.text("Apuntador: questions only")
        case .unavailable: L10n.text("Apuntador: unavailable")
        }
    }

    private var statusSymbol: String {
        switch readiness {
        case .ready, .readyThroughProvider: PVSymbol.success
        case .questionsOnly: PVSymbol.warning
        case .unavailable: PVSymbol.error
        }
    }

    private var statusTint: Color {
        switch readiness {
        case .ready, .readyThroughProvider: .green
        case .questionsOnly: .orange
        case .unavailable: .red
        }
    }

    private var statusCause: String {
        switch readiness {
        case .ready:
            L10n.text("Question detection and on-device answers work on this Mac.")
        case .readyThroughProvider:
            L10n.text(
                // swiftlint:disable:next line_length
                "Questions and general-knowledge answers through your provider. Meeting-context answers need Apple Intelligence.")
        case .questionsOnly(let cause):
            cause
        case .unavailable:
            L10n.text("Reinstall Portavoz to restore its bundled offline question detector.")
        }
    }
}
