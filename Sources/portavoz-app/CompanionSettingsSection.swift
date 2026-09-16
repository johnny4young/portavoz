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
            Text("Detects questions during a recording and suggests answers. Without an answer engine, cards show the question only.")
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
                "When someone says your name, Apuntador marks the card as asked to you. Empty uses your macOS account name.",
                companionUserName.isEmpty ? NSFullUserName() : companionUserName))
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Your talk time after each meeting", isOn: $mirrorAfterMeeting)
                .accessibilityIdentifier("settings-mirror-after-meeting")
            Text("After meetings of five minutes or more, show your talk time next to your average.")
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
                    systemImage: PVSymbol.error
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
            Label("Question detection and on-device answer suggestions are ready.", systemImage: PVSymbol.success)
                .foregroundStyle(.green)
                .accessibilityIdentifier("settings-apuntador-status")
        case .requiresMacOS26:
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Apuntador question detection is ready on this Mac.",
                    systemImage: PVSymbol.success
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
                .accessibilityIdentifier("settings-apuntador-status")
                // swiftlint:disable:next line_length
                Text("On macOS Sequoia, cards show the question only. Generated answers need macOS Tahoe with Apple Intelligence, or a provider you enable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .unavailable(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Apuntador question detection is ready.",
                    systemImage: PVSymbol.success
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
        L10n.format("Generated answers are unavailable: %@. Cards show the question only.", reason)
    }
}
