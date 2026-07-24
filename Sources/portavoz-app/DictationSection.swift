import SwiftUI

/// Settings section for system-wide dictation: the enable toggle and both
/// physical triggers (hotkey + mouse button). Registering/unregistering
/// happens immediately via the shared `DictationController` so no restart
/// is needed.
struct DictationSection: View {
    @Environment(AppServices.self) private var services
    @AppStorage(DictationController.defaultsKey) private var enabled = false

    var body: some View {
        Section("Dictation") {
            Toggle("Dictate anywhere", isOn: $enabled)
                .accessibilityIdentifier("settings-dictation-toggle")
                .onChange(of: enabled) {
                    services.dictation.syncHotkey(services: services)
                    services.dictation.syncMousePTT(services: services)
                }
            if enabled {
                HotkeyRecorder {
                    services.dictation.syncHotkey(services: services)
                }
                MouseButtonRecorder {
                    services.dictation.syncMousePTT(services: services)
                }
            }
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Press ⌥⌘D in any app, speak, press it again: your words are typed where your cursor is — transcribed on this Mac with your custom vocabulary, never stored. Inserting text needs the Accessibility permission (macOS asks on first use)."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
