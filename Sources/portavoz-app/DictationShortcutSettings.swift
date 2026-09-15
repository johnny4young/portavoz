import SwiftUI

/// Presentation of the one process-owned registration. Retrying a shortcut
/// never begins capture or asks for microphone/Accessibility permission.
struct DictationShortcutSettings: View {
    let shortcut: DictationShortcut
    let retry: () -> Void

    var body: some View {
        HotkeyRecorder(setting: shortcut.setting, onChange: retry)
        if shortcut.usedFallback {
            Text(L10n.format(
                "The saved shortcut is invalid. Using %@ instead.",
                shortcut.setting.label))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings-dictation-shortcut-recovered")
        }
        if shortcut.availability == .unavailable {
            Label(L10n.format("Shortcut %@ is unavailable.", shortcut.setting.label),
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityIdentifier("settings-dictation-shortcut-unavailable")
            Text("Another app or the system may reserve it. Choose another combination or retry.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Retry shortcut", action: retry)
                .accessibilityIdentifier("settings-dictation-shortcut-retry")
        } else {
            Text(L10n.format("Use %@ to start dictation; press it again to finish.", shortcut.setting.label))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings-dictation-shortcut-help")
        }
        if shortcut.usedFallback || shortcut.setting != .default {
            Button("Use default shortcut") {
                shortcut.useDefault()
                retry()
            }
            .accessibilityIdentifier("settings-dictation-shortcut-default")
        }
    }
}
