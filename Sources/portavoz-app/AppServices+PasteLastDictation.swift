import Carbon.HIToolbox
import Foundation

/// Optional fixed shortcut for pasting the last dictation; off by default.
/// ⌥⌘V and ⇧⌥⌘V already mean "move" and "paste and match style" in many apps.
enum PasteLastShortcut {
    static let defaultsKey = "dictationPasteLastHotkey"
    static let keyCode = UInt32(kVK_ANSI_V)
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
}

extension AppServices {
    func pasteLastDictation(unpolished: Bool = false) {
        dictation.pasteLastDictation(using: makeDictationSessionDependencies(), unpolished: unpolished)
    }

    func syncPasteLastShortcut() {
        pasteLastHotkey?.unregister()
        pasteLastHotkey = nil
        let wanted = defaults.bool(forKey: DictationController.defaultsKey)
            && defaults.bool(forKey: PasteLastShortcut.defaultsKey)
        // Disposable launches never register Carbon hotkeys.
        guard wanted, !usesTemporaryMeetingStore else {
            pasteLastShortcutUnavailable = false
            return
        }
        pasteLastHotkey = GlobalHotkey(
            keyCode: PasteLastShortcut.keyCode, modifiers: PasteLastShortcut.modifiers
        ) { [weak self] in self?.pasteLastDictation() }
        pasteLastShortcutUnavailable = pasteLastHotkey == nil
    }
}
