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
        restore(from: defaults).setting
    }

    static func restore(from defaults: UserDefaults = .standard) -> (setting: HotkeySetting, usedFallback: Bool) {
        let keys = [keyCodeKey, modifiersKey, labelKey]
        guard keys.contains(where: { defaults.object(forKey: $0) != nil }) else {
            return (.default, false)
        }
        let allowedModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        guard let code = storedUInt32(defaults.object(forKey: keyCodeKey)),
              code <= UInt32(UInt16.max),
              let modifiers = storedUInt32(defaults.object(forKey: modifiersKey)),
              modifiers & ~allowedModifiers == 0,
              modifiers & UInt32(cmdKey | optionKey) != 0,
              let storedLabel = defaults.object(forKey: labelKey) as? String, storedLabel.count <= 64,
              let label = displayLabel(keyCode: code, modifiers: modifiers, storedLabel: storedLabel)
        else { return (.default, true) }
        return (HotkeySetting(keyCode: code, modifiers: modifiers, label: label), false)
    }

    private static func storedUInt32(_ value: Any?) -> UInt32? {
        // UserDefaults.integer coerces malformed types and truncates fractions;
        // UInt32(integer) then traps for negative or oversized persisted values.
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return UInt32(number.stringValue)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(Int(keyCode), forKey: Self.keyCodeKey)
        defaults.set(Int(modifiers), forKey: Self.modifiersKey)
        defaults.set(label, forKey: Self.labelKey)
        // A deliberate edit supersedes startup overrides for this setting.
        // Keep unrelated command-line/volatile values and their precedence.
        var overrides = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        for key in [Self.keyCodeKey, Self.modifiersKey, Self.labelKey] {
            overrides.removeValue(forKey: key)
        }
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
    }

    /// Builds a setting from a captured key event. nil when the combo has
    /// no command/option modifier — a bare letter as a GLOBAL hotkey would
    /// hijack normal typing everywhere.
    static func from(event: NSEvent) -> HotkeySetting? {
        let flags = event.modifierFlags
        guard flags.contains(.command) || flags.contains(.option) else { return nil }
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        let code = UInt32(event.keyCode)
        let key = specialKeyLabel(code) ?? event.charactersIgnoringModifiers?.uppercased() ?? "?"
        return HotkeySetting(keyCode: code, modifiers: carbon, label: modifierLabel(carbon) + key)
    }
}

/// "Click, press your combo": a minimal hotkey recorder. While armed, a
/// LOCAL key monitor captures the next combination; Esc cancels.
struct HotkeyRecorder: View {
    @State private var recording = false
    @State private var monitor: Any?
    let setting: HotkeySetting
    /// Called with the accepted new setting AFTER it was persisted.
    let onChange: () -> Void

    var body: some View {
        HStack {
            Text("Dictation hotkey")
            Spacer()
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Text(recording ? L10n.text("Press keys…") : setting.label)
                    .font(.body.monospaced())
                    .frame(minWidth: 90)
            }
            .accessibilityIdentifier("settings-dictation-hotkey-recorder")
        }
        .onDisappear(perform: stopRecording)
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
