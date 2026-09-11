import Foundation
import SwiftUI

struct CompanionSettingsSection: View {
    let capability: FoundationModelsCapability
    let detectorAvailable: Bool
    @Binding var companionEnabled: Bool
    @Binding var companionUserName: String
    @Binding var mirrorAfterMeeting: Bool

    var body: some View {
        Section("Apuntador") {
            capabilityStatus
            Toggle("Enable Apuntador for recordings", isOn: $companionEnabled)
                .accessibilityIdentifier("settings-apuntador-enabled")
                .disabled(!detectorAvailable)
            // swiftlint:disable:next line_length
            Text("Turn it on here or from the recording toolbar. Apuntador detects questions privately; it never speaks or answers for you. Without an available answer engine, it shows an honest question-only card.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(
                "Your name in meetings",
                text: $companionUserName,
                prompt: Text(NSFullUserName())
            )
            .autocorrectionDisabled()
            Text(L10n.format(
                // swiftlint:disable:next line_length
                "When someone asks for you by name (\"%@\", what do you think?), Apuntador highlights the card as “asked you” even when it is not a technical question. Empty = use your macOS account name.",
                companionUserName.isEmpty ? NSFullUserName() : companionUserName))
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Mirror after each meeting", isOn: $mirrorAfterMeeting)
                .accessibilityIdentifier("settings-mirror-after-meeting")
            // swiftlint:disable:next line_length
            Text("When a meeting has two or more speakers and runs at least five minutes, show a private card with your own numbers next to your usual average — measured on your Mac, never judged.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var capabilityStatus: some View {
        if !detectorAvailable {
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Apuntador question detection is unavailable.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
                .accessibilityIdentifier("settings-apuntador-status")
                Text("Reinstall Portavoz to restore its bundled offline question detector.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            capabilityStatusWithDetector
        }
    }

    @ViewBuilder
    private var capabilityStatusWithDetector: some View {
        switch capability {
        case .available:
            // swiftlint:disable:next line_length
            Label("Question detection and on-device answer suggestions are ready.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("settings-apuntador-status")
        case .requiresMacOS26:
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Apuntador question detection is ready on this Mac.",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
                .accessibilityIdentifier("settings-apuntador-status")
                // swiftlint:disable:next line_length
                Text("On macOS Sequoia, the bundled bilingual detector works fully offline and shows question-only cards. On-device generated answers require macOS Tahoe with Apple Intelligence; an explicitly enabled BYOK provider may answer general knowledge questions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .unavailable(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Apuntador question detection is ready.",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
                .accessibilityIdentifier("settings-apuntador-status")
                Text(unavailableMessage(reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func unavailableMessage(_ reason: String) -> String {
        // swiftlint:disable:next line_length
        L10n.format("Apple's optional answer enhancement is unavailable: %@. The bundled detector still works fully offline and shows question-only cards; explicitly enabled BYOK remains limited to general knowledge questions.", reason)
    }
}
