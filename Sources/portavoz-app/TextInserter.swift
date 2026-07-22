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

    /// Browsers and Electron apps service the synthesized ⌘V long after the
    /// event posts; restoring the clipboard earlier makes them paste the OLD
    /// contents instead of the dictation.
    static let restoreDelay: Duration = .milliseconds(1500)

    /// True when the element that would receive the paste is a password
    /// field. Checked at delivery time — focus can move between starting a
    /// dictation and finishing it — so spoken text can never land in a
    /// secure field, where it would sit as a plaintext secret.
    @MainActor
    static func focusedFieldIsSecure() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let focused,
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        // The cast through CFTypeRef is the sanctioned bridge for AX values.
        // swiftlint:disable:next force_cast
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return isSecureField(role: role as? String, subrole: subrole as? String)
    }

    /// Pure decision, split out for tests: secure text fields report the
    /// `AXSecureTextField` subrole (some apps put it in the role instead).
    static func isSecureField(role: String?, subrole: String?) -> Bool {
        let secure = "AXSecureTextField"
        return role == secure || subrole == secure
    }

    /// Pastes `text` into the frontmost app, then restores the previous
    /// clipboard contents after the paste has landed. Waits for the physical
    /// hotkey modifiers to be released first, so the synthesized ⌘V cannot
    /// combine with a still-held ⌥/⇧/⌃ into a different app shortcut.
    @MainActor
    static func insert(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(of: pasteboard)
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        await waitForModifierRelease()
        postCommandV()

        Task {
            try? await Task.sleep(for: restoreDelay)
            restoreIfStillOurs(snapshot, expectedChangeCount: ourChangeCount)
        }
    }

    /// Restore only when the pasteboard still holds our dictation: a changed
    /// `changeCount` means the user or a clipboard manager took over, and
    /// restoring would clobber their data. Value comparison cannot detect
    /// that — an identical string written by a manager still advances the
    /// count, and rich content never compares as `String`.
    @MainActor
    private static func restoreIfStillOurs(
        _ snapshot: PasteboardSnapshot?,
        expectedChangeCount: Int
    ) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == expectedChangeCount else { return }
        guard let snapshot else {
            pasteboard.clearContents()
            return
        }
        snapshot.restore(to: pasteboard)
    }

    /// Bounded wait for every physical modifier to be released. The dictation
    /// hotkey is a modifier chord (⌥⌘D by default); on the toggle path the
    /// paste can fire milliseconds after the keypress, while the chord is
    /// still down. The bound keeps a stuck key from blocking delivery.
    @MainActor
    private static func waitForModifierRelease() async {
        for _ in 0..<50 {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let held: CGEventFlags = [
                .maskCommand, .maskAlternate, .maskControl, .maskShift
            ]
            if flags.isDisjoint(with: held) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = pasteKeyCode()
        let keyDown = CGEvent(
            keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(
            keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// The key that produces "v" in the CURRENT layout. Hardcoding the QWERTY
    /// position pastes garbage on layouts where shortcuts follow the letters
    /// (Dvorak Left/Right Hand); resolving blindly breaks "Dvorak - QWERTY ⌘",
    /// which keeps shortcuts on QWERTY positions. Non-Latin layouts fall back
    /// to the QWERTY position, which macOS maps for shortcuts.
    private static func pasteKeyCode() -> CGKeyCode {
        let qwertyV = CGKeyCode(kVK_ANSI_V)
        if currentLayoutUsesQwertyCommandPositions() { return qwertyV }
        return keyCode(for: "v") ?? qwertyV
    }

    private static func currentLayoutUsesQwertyCommandPositions() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
            let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return true }
        let sourceID = Unmanaged<CFString>.fromOpaque(idPointer)
            .takeUnretainedValue() as String
        let qwertyCommandLayouts = [
            "DVORAK-QWERTY", "US", "ABC", "AUSTRALIAN", "BRITISH", "CANADIAN",
            "USINTERNATIONAL"
        ]
        let upper = sourceID.uppercased()
        return qwertyCommandLayouts.contains { upper.contains($0) }
    }

    private static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
            let layoutPointer = TISGetInputSourceProperty(
                source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = unsafeBitCast(layoutPointer, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(bytes)
            .assumingMemoryBound(to: UCKeyboardLayout.self)
        let target = character.lowercased()
        // Letter keys all live in the 0...50 virtual-keycode range.
        for candidate: UInt16 in 0...50 {
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout, candidate, UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, chars.count, &length, &chars)
            guard status == noErr, length > 0,
                let scalar = UnicodeScalar(chars[0])
            else { continue }
            if Character(scalar).lowercased() == target {
                return CGKeyCode(candidate)
            }
        }
        return nil
    }
}

/// Full multi-type snapshot of the pasteboard. Saving only the plain string
/// (the previous behavior) silently destroyed rich content — an image, file
/// URLs, styled text — the moment a dictation landed.
struct PasteboardSnapshot {
    private let types: [NSPasteboard.PasteboardType]
    private let values: [NSPasteboard.PasteboardType: Value]

    private enum Value {
        case data(Data)
        case string(String)
        case propertyList(Any)
    }

    init?(of pasteboard: NSPasteboard) {
        let types = pasteboard.types ?? []
        var values: [NSPasteboard.PasteboardType: Value] = [:]
        for type in types {
            if let data = pasteboard.data(forType: type) {
                values[type] = .data(data)
            } else if let string = pasteboard.string(forType: type) {
                values[type] = .string(string)
            } else if let list = pasteboard.propertyList(forType: type) {
                values[type] = .propertyList(list)
            }
        }
        guard !values.isEmpty else { return nil }
        self.types = types
        self.values = values
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.declareTypes(types, owner: nil)
        for (type, value) in values {
            switch value {
            case .data(let data): pasteboard.setData(data, forType: type)
            case .string(let string): pasteboard.setString(string, forType: type)
            case .propertyList(let list): pasteboard.setPropertyList(list, forType: type)
            }
        }
    }
}
