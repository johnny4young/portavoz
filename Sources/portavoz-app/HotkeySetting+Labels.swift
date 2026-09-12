import Carbon.HIToolbox
import Foundation

extension HotkeySetting {
    static func displayLabel(keyCode: UInt32, modifiers: UInt32, storedLabel: String) -> String? {
        if let key = specialKeyLabel(keyCode) {
            return modifierLabel(modifiers) + key
        }
        guard !storedLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !storedLabel.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return storedLabel
    }

    static func modifierLabel(_ modifiers: UInt32) -> String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }
            .map(\.1).joined()
    }

    private static let specialLabels: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "␣",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟"
    ]
    private static let functionKeyCodes = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7,
        kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13,
        kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ]

    static func specialKeyLabel(_ code: UInt32) -> String? {
        if let label = specialLabels[Int(code)] { return label }
        guard let index = functionKeyCodes.firstIndex(of: Int(code)) else { return nil }
        return "F\(index + 1)"
    }
}
