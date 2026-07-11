import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Inserts dictated text into whatever app is frontmost: paste-and-restore
/// (the reliable industry pattern — synthetic per-character typing breaks
/// with non-ASCII and secure fields). The synthetic ⌘V needs macOS's
/// Accessibility permission; `canInsert` checks it and (optionally)
/// triggers the system prompt.
enum TextInserter {
    @MainActor
    static func canInsert(promptIfNeeded: Bool) -> Bool {
        if AXIsProcessTrusted() { return true }
        guard promptIfNeeded else { return false }
        // Literal instead of kAXTrustedCheckOptionPrompt: the C global is
        // not concurrency-safe under Swift 6; its value is this stable key.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Pastes `text` into the frontmost app, then restores the previous
    /// clipboard contents after the paste has landed.
    @MainActor
    static func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCommandV()

        // Give the frontmost app time to read the pasteboard before the
        // old contents come back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let current = NSPasteboard.general.string(forType: .string)
            guard current == text else { return }  // someone else already wrote
            NSPasteboard.general.clearContents()
            if let previous {
                NSPasteboard.general.setString(previous, forType: .string)
            }
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(
            keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(
            keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
