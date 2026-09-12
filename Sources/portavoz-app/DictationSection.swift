import SwiftUI

/// Settings section for system-wide dictation: the enable toggle, both
/// physical triggers (hotkey + mouse button), the constrained language,
/// and the deterministic dictionary tier. Registering/unregistering
/// happens immediately via the shared `DictationController` so no restart
/// is needed.
struct DictationSection: View {
    @Environment(AppServices.self) private var services
    @AppStorage(DictationController.defaultsKey) private var enabled = false
    @AppStorage(DictationController.languageKey) private var language = "auto"
    @AppStorage(DictationController.fillerFilterKey) private var filterFillers = true

    var body: some View {
        Section("Dictation") {
            Toggle("Dictate anywhere", isOn: $enabled)
                .accessibilityIdentifier("settings-dictation-toggle")
                .onChange(of: enabled) {
                    services.dictation.syncHotkey(services: services)
                    services.dictation.syncMousePTT(
                        services: services, promptIfNeeded: enabled)
                }
            if enabled {
                DictationShortcutSettings(shortcut: services.dictation.shortcut) {
                    services.dictation.syncHotkey(services: services)
                }
                MouseButtonRecorder {
                    services.dictation.syncMousePTT(
                        services: services, promptIfNeeded: true)
                }
                Picker("Dictation language", selection: $language) {
                    Text("Automatic (Spanish + English)").tag("auto")
                    Text("Spanish").tag("es")
                    Text("English").tag("en")
                }
                .accessibilityIdentifier("settings-dictation-language")
                Toggle("Filter out filler words", isOn: $filterFillers)
                    .accessibilityIdentifier("settings-dictation-filler")
                DictationDictionaryEditor()
            }
            Text(
                "Dictation stays on this Mac and is not stored. Inserting text requires Accessibility permission."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
