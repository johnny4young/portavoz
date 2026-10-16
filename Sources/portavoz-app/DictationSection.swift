import SwiftUI

/// Settings section for system-wide dictation: the enable toggle, both
/// physical triggers (hotkey + mouse button), the language preference,
/// and the deterministic dictionary tier. Registering/unregistering
/// happens immediately via the shared `DictationController` so no restart
/// is needed.
struct DictationSection: View {
    @Environment(AppServices.self) private var services
    @AppStorage(DictationController.defaultsKey) private var enabled = false
    @AppStorage(DictationController.languageKey) private var language = "auto"
    @AppStorage(LiveSpeechSelection.dictationKey) private var liveEngine =
        LiveSpeechSelection.parakeet.rawValue
    @AppStorage(DictationController.fillerFilterKey) private var filterFillers = true
    @AppStorage(DictationSoundCue.defaultsKey) private var playsSounds = false
    @AppStorage(DictationPrewarmPolicy.defaultsKey) private var prewarms = false
    @AppStorage(AppModelMemoryPreferences.key) private var memoryProfile =
        AppModelMemoryPreferences.Profile.balanced.rawValue

    var body: some View {
        Section("Dictation") {
            Toggle("Dictate anywhere", isOn: $enabled)
                .accessibilityIdentifier("settings-dictation-toggle")
                .onChange(of: enabled) {
                    services.dictation.syncHotkey(services: services)
                    services.dictation.syncMousePTT(
                        services: services, promptIfNeeded: enabled)
                    services.prewarmDictationIfConfigured()
                }
            if enabled {
                DictationShortcutSettings(shortcut: services.dictation.shortcut) {
                    services.dictation.syncHotkey(services: services)
                }
                MouseButtonRecorder {
                    services.dictation.syncMousePTT(
                        services: services, promptIfNeeded: true)
                }
                Toggle("Play start and stop sounds", isOn: $playsSounds)
                    .accessibilityIdentifier("settings-dictation-sounds")
                prewarmControls
                Picker("Dictation language", selection: $language) {
                    Text("Automatic").tag("auto")
                    Text("Spanish").tag("es")
                    Text("English").tag("en")
                }
                .accessibilityIdentifier("settings-dictation-language")
                AppleSpeechChoiceControls(
                    selection: $liveEngine, language: language,
                    identifierPrefix: "settings-dictation-live")
                Text("Spanish and English can still mix. This setting mainly keeps out other writing systems.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-dictation-language-support")
                DictationTextSettingsSection(model: services.dictationTextSettings) {
                    await services.selectDictationProfileApplication()
                }
                // Literal mode never applies these; keep them visible but inert
                // until a default or application profile uses Clean mode.
                let cleanInUse = services.dictationTextSettings.cleanModeInUse
                Toggle("Filter out filler words", isOn: $filterFillers)
                    .accessibilityIdentifier("settings-dictation-filler")
                    .disabled(!cleanInUse)
                DictationDictionaryEditor()
                    .disabled(!cleanInUse)
                if !cleanInUse {
                    Text("Filler filtering and replacements apply only in Clean mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-dictation-clean-only")
                }
            }
            Text(
                "Dictation stays on this Mac and is not stored. Inserting text requires Accessibility permission."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var prewarmControls: some View {
        let lightweight = memoryProfile == AppModelMemoryPreferences.Profile.lightweight.rawValue
        Toggle("Load the dictation model at launch", isOn: $prewarms)
            .accessibilityIdentifier("settings-dictation-prewarm")
            .disabled(lightweight)
            .onChange(of: prewarms) { services.prewarmDictationIfConfigured() }
        Group {
            if lightweight {
                Text("Not available with Lightweight model memory.")
            } else {
                Text("The first dictation starts faster. The model still unloads after a few idle minutes.")
            }
        }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings-dictation-prewarm-note")
    }
}
