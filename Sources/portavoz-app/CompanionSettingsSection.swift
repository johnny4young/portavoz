import Foundation
import SwiftUI

struct CompanionSettingsSection: View {
    let capability: FoundationModelsCapability
    @Binding var companionEnabled: Bool
    @Binding var companionUserName: String
    @Binding var mirrorAfterMeeting: Bool

    var body: some View {
        Section("Companion") {
            capabilityStatus
            if capability.isAvailable {
                Toggle("Enable Companion for recordings", isOn: $companionEnabled)
                    .accessibilityIdentifier("settings-companion-enabled")
                // swiftlint:disable:next line_length
                Text("Turn it on here or from the recording toolbar. Companion detects questions and suggests private answer cards; it never speaks or answers for you.")
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
                    "When someone asks for you by name (\"%@\", what do you think?), Companion highlights the card as “asked you” even when it is not a technical question. Empty = use your macOS account name.",
                    companionUserName.isEmpty ? NSFullUserName() : companionUserName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-companion-name-guidance")
            }

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
        switch capability {
        case .available:
            Label("Companion is ready on this Mac.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("settings-companion-status")
        case .requiresMacOS26:
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Live Companion requires macOS 26 and Apple Intelligence.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout.weight(.medium))
                // swiftlint:disable:next line_length
                Text("On macOS Sequoia, summaries and Refine still work with Ollama, Built-in (MLX), and Whisper. An external BYOK provider cannot enable Companion yet because question detection still uses Apple's on-device model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings-companion-status")
        case .unavailable(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Live Companion needs Apple Intelligence.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout.weight(.medium))
                Text(unavailableMessage(reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings-companion-status")
        }
    }

    private func unavailableMessage(_ reason: String) -> String {
        // swiftlint:disable:next line_length
        L10n.format("Apple's on-device model is unavailable: %@. Choose another summary engine if needed; BYOK cannot replace Companion's question detector yet.", reason)
    }
}
