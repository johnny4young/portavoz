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
    @AppStorage(ModifierKeySetting.defaultsKey) private var modifierKey = ModifierKeySetting.off.rawValue
    @AppStorage(DictationSpeechGate.defaultsKey) private var skipsSilence = DictationSpeechGate.enabledByDefault
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
                    services.dictation.syncModifierPTT(services: services, promptIfNeeded: enabled)
                    services.prewarmDictationIfConfigured()
                    if enabled { Task { await services.prepareSpeechGateIfEnabled() } }
                }
            if enabled {
                DictationShortcutSettings(shortcut: services.dictation.shortcut) {
                    services.dictation.syncHotkey(services: services)
                }
                MouseButtonRecorder {
                    services.dictation.syncMousePTT(
                        services: services, promptIfNeeded: true)
                }
                modifierKeyControls
                Toggle("Play start and stop sounds", isOn: $playsSounds)
                    .accessibilityIdentifier("settings-dictation-sounds")
                prewarmControls
                speechGateControls
                Picker("Dictation language", selection: $language) {
                    Text("Automatic").tag("auto")
                    Text("Spanish").tag("es")
                    Text("English").tag("en")
                }
                .accessibilityIdentifier("settings-dictation-language")
                AppleSpeechChoiceControls(
                    selection: $liveEngine, language: language,
                    identifierPrefix: "settings-dictation-live", offersUltra: true)
                .onChange(of: liveEngine) {
                    if liveEngine == LiveSpeechSelection.parakeetUltra.rawValue {
                        Task { await services.installParakeetUltraModel() }
                    }
                    services.prewarmDictationIfConfigured()
                }
                if liveEngine == LiveSpeechSelection.parakeetUltra.rawValue {
                    ultraControls
                }
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
                Text("In Clean mode, say “new line” or “new paragraph” to start one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-dictation-spoken-commands")
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

    @ViewBuilder private var modifierKeyControls: some View {
        Picker("Hold a key to dictate", selection: $modifierKey) {
            Text("Off").tag(ModifierKeySetting.off.rawValue)
            Text("Fn (🌐)").tag(ModifierKeySetting.function.rawValue)
            Text("Right Option").tag(ModifierKeySetting.rightOption.rawValue)
            Text("Right Command").tag(ModifierKeySetting.rightCommand.rawValue)
        }
        .accessibilityIdentifier("settings-dictation-modifier-key")
        .onChange(of: modifierKey) {
            services.dictation.syncModifierPTT(services: services, promptIfNeeded: true)
        }
        if modifierKey != ModifierKeySetting.off.rawValue, services.dictation.modifierTrigger.unavailable {
            Text("Holding a key needs Accessibility permission for Portavoz in System Settings › Privacy & Security.")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-dictation-modifier-unavailable")
        } else if modifierKey != ModifierKeySetting.off.rawValue {
            Text("Hold the key while you speak and release it to paste. Shortcuts that use the key keep working.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-dictation-modifier-note")
        }
        if modifierKey == ModifierKeySetting.function.rawValue {
            Text("So macOS doesn't also react, set “Press 🌐 key to” to “Do Nothing” in System Settings › Keyboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-dictation-modifier-fn-note")
        }
    }

    @ViewBuilder private var ultraControls: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(ultraNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-dictation-live-ultra-status")
            if services.parakeetUltraModel == .missing {
                Button("Download") { Task { await services.installParakeetUltraModel() } }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings-dictation-live-ultra-install")
            } else if services.parakeetUltraModel == .failed {
                Button("Retry") { Task { await services.installParakeetUltraModel() } }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings-dictation-live-ultra-retry")
            }
        }
        .task { await services.refreshParakeetUltraModel() }
    }

    private var ultraNote: String {
        switch services.parakeetUltraModel {
        case .downloading(let percent):
            L10n.format("Downloading Parakeet Ultra (613 MB)… %d%%", percent)
        case .ready:
            L10n.text("Ultra is ready for dictation. Meetings, and dictation during a recording, use Parakeet.")
        case .failed:
            L10n.text("Parakeet Ultra couldn't be downloaded. Until it is, dictation uses Parakeet.")
        case .unknown:
            L10n.text("Checking Parakeet Ultra…")
        case .missing:
            L10n.text("Parakeet Ultra isn't downloaded yet. Until it is, dictation uses Parakeet.")
        }
    }

    @ViewBuilder private var speechGateControls: some View {
        Toggle("Skip dictations without speech", isOn: $skipsSilence)
            .accessibilityIdentifier("settings-dictation-speech-gate")
            .onChange(of: skipsSilence) {
                if skipsSilence { Task { await services.installSpeechGateModel() } }
            }
        HStack(alignment: .firstTextBaseline) {
            Text(speechGateNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-dictation-speech-gate-status")
            if skipsSilence, services.speechGateModel == .missing {
                Button("Download") { Task { await services.installSpeechGateModel() } }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings-dictation-speech-gate-install")
            } else if skipsSilence, services.speechGateModel == .failed {
                Button("Retry") { Task { await services.installSpeechGateModel() } }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings-dictation-speech-gate-retry")
            }
        }
        .task { await services.refreshSpeechGateModel() }
    }

    private var speechGateNote: String {
        switch services.speechGateModel {
        case .downloading(let percent):
            L10n.format("Downloading the voice detector (1 MB)… %d%%", percent)
        case .failed where skipsSilence:
            L10n.text("The voice detector couldn't be downloaded. Until it is, dictations are pasted as before.")
        case .missing where skipsSilence:
            L10n.text("The voice detector isn't installed yet. Until it is, dictations are pasted as before.")
        default:
            // One-line UI copy.
            // swiftlint:disable:next line_length
            L10n.text("Silence and background noise are offered to copy instead of being pasted. Uses a 1 MB voice detector on this Mac.")
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
