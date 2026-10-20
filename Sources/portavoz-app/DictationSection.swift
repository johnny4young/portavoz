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
    @AppStorage(DictationCompactIndicator.defaultsKey) private var compactIndicator = false
    @AppStorage(DictationPrewarmPolicy.defaultsKey) private var prewarms = false
    @AppStorage(ModifierKeySetting.defaultsKey) private var modifierKey = ModifierKeySetting.off.rawValue
    @AppStorage(DictationAutoStop.defaultsKey) private var autoStops = false
    @AppStorage(DictationAutoStop.pauseKey) private var autoStopPause = DictationAutoStop.defaultPause
    @AppStorage(PasteLastShortcut.defaultsKey) private var pasteLastShortcut = false
    @AppStorage(DictationSpeechGate.defaultsKey) private var skipsSilence = DictationSpeechGate.enabledByDefault
    @AppStorage(AppModelMemoryPreferences.key) private var memoryProfile =
        AppModelMemoryPreferences.Profile.balanced.rawValue

    var body: some View {
        Section("Dictation") {
            Toggle("Dictate anywhere", isOn: $enabled)
                .accessibilityIdentifier("settings-dictation-toggle")
                .onChange(of: enabled) { services.applyDictationEnabled(enabled) }
            if enabled {
                DictationShortcutSettings(shortcut: services.dictation.shortcut) {
                    services.dictation.syncHotkey(services: services)
                }
                DictationPracticeView(identifierPrefix: "settings-dictation")
                MouseButtonRecorder {
                    services.dictation.syncMousePTT(
                        services: services, promptIfNeeded: true)
                }
                modifierKeyControls
                pasteLastControls
                Toggle("Play start and stop sounds", isOn: $playsSounds)
                    .accessibilityIdentifier("settings-dictation-sounds")
                Toggle("Show only a small indicator", isOn: $compactIndicator)
                    .accessibilityIdentifier("settings-dictation-compact")
                Text("While you dictate, see just the audio level and the time, without the live text or buttons.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-dictation-compact-note")
                prewarmControls
                speechGateControls
                autoStopControls
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
                        services.startParakeetUltraDownload()
                    } else {
                        services.cancelParakeetUltraDownload()
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

    @ViewBuilder private var autoStopControls: some View {
        Toggle("Stop after a pause", isOn: $autoStops)
            .accessibilityIdentifier("settings-dictation-auto-stop")
            .onChange(of: autoStops) {
                // Turning it on is the consent for the same 1 MB voice detector.
                if autoStops { Task { await services.installSpeechGateModel() } }
            }
        if autoStops {
            Picker("Pause length", selection: $autoStopPause) {
                ForEach(DictationAutoStop.pauses, id: \.self) { seconds in
                    Text(L10n.format("%.1f seconds", seconds)).tag(seconds)
                }
            }
            .accessibilityIdentifier("settings-dictation-auto-stop-pause")
        }
        Text(autoStops && [.missing, .failed].contains(services.speechGateModel)
            ? L10n.text("Needs the voice detector above. Until it is installed, dictation stops only when you do.")
            : L10n.text("Only when you tap to start. Holding a key or button still stops when you let go."))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings-dictation-auto-stop-note")
    }

    @ViewBuilder private var pasteLastControls: some View {
        Toggle("Paste the last dictation with ⌃⌥⌘V", isOn: $pasteLastShortcut)
            .accessibilityIdentifier("settings-dictation-paste-last-hotkey")
            .onChange(of: pasteLastShortcut) { services.syncPasteLastShortcut() }
        let taken = services.pasteLastShortcutUnavailable && pasteLastShortcut
        // swiftlint:disable:next line_length
        Text(taken ? L10n.text("Another app already uses ⌃⌥⌘V. Paste the last dictation from the menu bar instead.") : L10n.text("The last dictation stays in memory for 15 minutes and is never saved. It is also in the menu bar."))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings-dictation-paste-last-note")
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
            switch services.parakeetUltraModel {
            case .missing:
                Button("Download") { services.startParakeetUltraDownload() }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings-dictation-live-ultra-install")
            case .failed:
                Button("Retry") { services.startParakeetUltraDownload() }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings-dictation-live-ultra-retry")
            case .downloading:
                Button("Cancel") { services.cancelParakeetUltraDownload() }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings-dictation-live-ultra-cancel")
            case .unknown, .ready:
                EmptyView()
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
