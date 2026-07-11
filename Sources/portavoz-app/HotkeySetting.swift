import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The dictation hotkey as stored settings: Carbon key code + Carbon
/// modifier mask + a display label ("⌥⌘D"). Pure and testable; the
/// recorder UI below writes it, `DictationController` reads it.
struct HotkeySetting: Equatable {
    static let keyCodeKey = "dictationHotkeyKeyCode"
    static let modifiersKey = "dictationHotkeyModifiers"
    static let labelKey = "dictationHotkeyLabel"

    var keyCode: UInt32
    /// Carbon mask (cmdKey/optionKey/controlKey/shiftKey).
    var modifiers: UInt32
    var label: String

    static let `default` = HotkeySetting(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(optionKey | cmdKey),
        label: "⌥⌘D")

    static func load(from defaults: UserDefaults = .standard) -> HotkeySetting {
        guard defaults.object(forKey: keyCodeKey) != nil else { return .default }
        return HotkeySetting(
            keyCode: UInt32(defaults.integer(forKey: keyCodeKey)),
            modifiers: UInt32(defaults.integer(forKey: modifiersKey)),
            label: defaults.string(forKey: labelKey) ?? HotkeySetting.default.label)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(Int(keyCode), forKey: Self.keyCodeKey)
        defaults.set(Int(modifiers), forKey: Self.modifiersKey)
        defaults.set(label, forKey: Self.labelKey)
    }

    /// Builds a setting from a captured key event. nil when the combo has
    /// no command/option modifier — a bare letter as a GLOBAL hotkey would
    /// hijack normal typing everywhere.
    static func from(event: NSEvent) -> HotkeySetting? {
        let flags = event.modifierFlags
        guard flags.contains(.command) || flags.contains(.option) else { return nil }
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) {
            carbon |= UInt32(controlKey)
            symbols += "⌃"
        }
        if flags.contains(.option) {
            carbon |= UInt32(optionKey)
            symbols += "⌥"
        }
        if flags.contains(.shift) {
            carbon |= UInt32(shiftKey)
            symbols += "⇧"
        }
        if flags.contains(.command) {
            carbon |= UInt32(cmdKey)
            symbols += "⌘"
        }
        let key = event.charactersIgnoringModifiers?.uppercased() ?? "?"
        return HotkeySetting(
            keyCode: UInt32(event.keyCode), modifiers: carbon, label: symbols + key)
    }
}

/// "Click, press your combo": a minimal hotkey recorder. While armed, a
/// LOCAL key monitor captures the next combination; Esc cancels.
struct HotkeyRecorder: View {
    @State private var recording = false
    @State private var monitor: Any?
    @State private var label = HotkeySetting.load().label
    /// Called with the accepted new setting AFTER it was persisted.
    let onChange: () -> Void

    var body: some View {
        HStack {
            Text("Dictation hotkey")
            Spacer()
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Text(recording ? L10n.text("Press keys…") : label)
                    .font(.body.monospaced())
                    .frame(minWidth: 90)
            }
            .accessibilityIdentifier("settings-dictation-hotkey-recorder")
        }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stopRecording() }
            guard event.keyCode != UInt16(kVK_Escape) else { return nil }
            guard let setting = HotkeySetting.from(event: event) else {
                NSSound.beep()  // combo without ⌘/⌥ would hijack typing
                return nil
            }
            setting.save()
            label = setting.label
            onChange()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
