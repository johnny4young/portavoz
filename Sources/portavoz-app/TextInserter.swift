import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Inserts dictated text into a captured destination: paste-and-restore
/// (the reliable industry pattern — synthetic per-character typing breaks
/// with non-ASCII and secure fields). The synthetic ⌘V needs macOS's
/// Accessibility permission; `canInsert` checks it and (optionally)
/// triggers the system prompt.
enum TextInserter {
    struct BorrowedCFPropertyType<Value: AnyObject> {
        fileprivate let typeID: CFTypeID

        fileprivate init(typeID: CFTypeID) {
            self.typeID = typeID
        }
    }

    enum InsertionResult: Equatable {
        case inserted
        case secureField
        case focusUnavailable
        case targetChanged
        case modifiersStillPressed
        case clipboardUnavailable
        case eventUnavailable
        case cancelled
    }

    enum FocusedFieldSecurity: Equatable {
        case regular
        case secure
        case unavailable
    }

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

    /// Explicit recovery Copy is not a paste. If the write fails after
    /// declaration, restore only while this operation still owns the board.
    /// An unmaterializable existing representation must be left untouched.
    @MainActor
    static func copy(
        _ text: String, to pasteboard: NSPasteboard = .general,
        writeString: (NSPasteboard, String) -> Bool = { $0.setString($1, forType: .string) }
    ) -> Bool {
        guard !text.isEmpty else { return false }
        let existingTypes = pasteboard.types ?? []
        let snapshot = PasteboardSnapshot(of: pasteboard)
        guard existingTypes.isEmpty || snapshot?.isComplete == true else { return false }
        pasteboard.declareTypes([.string], owner: nil)
        let ourChangeCount = pasteboard.changeCount
        guard writeString(pasteboard, text) else {
            restoreIfStillOurs(snapshot, pasteboard: pasteboard, expectedChangeCount: ourChangeCount)
            return false
        }
        return true
    }

    @MainActor
    static func focusedElement(in owner: AXUIElement) -> AXUIElement? {
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(owner, kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let focused else { return nil }
        return checkedCFValue(focused, as: .accessibilityElement)
    }

    @MainActor
    static func fieldSecurity(of element: AXUIElement) -> FocusedFieldSecurity {
        var role: CFTypeRef?
        let roleStatus = AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &role)
        guard roleStatus == .success, let role = role as? String else {
            return .unavailable
        }
        if isSecureField(role: role, subrole: nil) { return .secure }

        var subrole: CFTypeRef?
        let subroleStatus = AXUIElementCopyAttributeValue(
            element, kAXSubroleAttribute as CFString, &subrole)
        switch subroleStatus {
        case .success:
            guard let subrole = subrole as? String else { return .unavailable }
            return classifyFocusedField(role: role, subrole: subrole)
        case .noValue, .attributeUnsupported:
            // Ordinary text controls commonly have no subrole. That is an
            // inspected absence, unlike a transient AX failure.
            return .regular
        default:
            return .unavailable
        }
    }

    static func classifyFocusedField(
        role: String?, subrole: String?
    ) -> FocusedFieldSecurity {
        guard role != nil else { return .unavailable }
        return isSecureField(role: role, subrole: subrole) ? .secure : .regular
    }

    /// Pure decision, split out for tests: secure text fields report the
    /// `AXSecureTextField` subrole (some apps put it in the role instead).
    static func isSecureField(role: String?, subrole: String?) -> Bool {
        let secure = "AXSecureTextField"
        return role == secure || subrole == secure
    }

    /// Dispatches `text` only to the captured process. Event dispatch is not
    /// acknowledgement that an external editor applied the edit. Waits for the physical
    /// hotkey modifiers to be released first, so the synthesized ⌘V cannot
    /// combine with a still-held ⌥/⇧/⌃ into a different app shortcut.
    @MainActor
    static func insert(
        _ text: String, into target: Target, pasteboard: NSPasteboard = .general,
        effects: Effects = .live
    ) async -> InsertionResult {
        guard target.processID > 0, effects.isProcessLive(target.processID) else { return .eventUnavailable }
        guard await effects.waitForModifiers() else {
            return Task.isCancelled ? .cancelled : .modifiersStillPressed
        }
        guard !Task.isCancelled else { return .cancelled }
        guard effects.isProcessLive(target.processID) else { return .eventUnavailable }

        // Both the modifier wait and a rich clipboard snapshot can service
        // another app. Validate on each side; never reinterpret a new target.
        let initialFailure = target.validate()
        guard !Task.isCancelled else { return .cancelled }
        if let initialFailure { return initialFailure }

        let snapshot = PasteboardSnapshot(of: pasteboard)
        pasteboard.declareTypes([.string], owner: nil)
        guard pasteboard.setString(text, forType: .string) else {
            restoreIfStillOurs(snapshot, pasteboard: pasteboard, expectedChangeCount: pasteboard.changeCount)
            return .clipboardUnavailable
        }
        let ourChangeCount = pasteboard.changeCount

        let targetFailure = target.validate()
        let failure = Task.isCancelled ? InsertionResult.cancelled : targetFailure
        if let failure {
            restoreIfStillOurs(snapshot, pasteboard: pasteboard, expectedChangeCount: ourChangeCount)
            return failure
        }
        // AX IPC can let another clipboard owner publish during validation.
        // Never send that owner's text as if it were this dictation.
        guard pasteboard.changeCount == ourChangeCount else { return .clipboardUnavailable }
        guard effects.isProcessLive(target.processID) else {
            restoreIfStillOurs(snapshot, pasteboard: pasteboard, expectedChangeCount: ourChangeCount)
            return .eventUnavailable
        }
        guard effects.post(target.processID) else {
            restoreIfStillOurs(snapshot, pasteboard: pasteboard, expectedChangeCount: ourChangeCount)
            return .eventUnavailable
        }

        Task {
            try? await Task.sleep(for: restoreDelay)
            restoreIfStillOurs(snapshot, pasteboard: pasteboard, expectedChangeCount: ourChangeCount)
        }
        return .inserted
    }

    @MainActor
    struct Effects {
        var waitForModifiers: () async -> Bool
        var post: (pid_t) -> Bool
        var isProcessLive: (pid_t) -> Bool = { _ in true }

        static var live: Self {
            Self(
                waitForModifiers: TextInserter.waitForModifierRelease,
                post: TextInserter.postCommandV,
                isProcessLive: { processID in
                    guard processID > 0,
                          let application = NSRunningApplication(processIdentifier: processID)
                    else { return false }
                    return !application.isTerminated
                })
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
        pasteboard: NSPasteboard,
        expectedChangeCount: Int
    ) {
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
    private static func waitForModifierRelease() async -> Bool {
        for _ in 0..<50 {
            guard !Task.isCancelled else { return false }
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let held: CGEventFlags = [
                .maskCommand, .maskAlternate, .maskControl, .maskShift
            ]
            if flags.isDisjoint(with: held) { return true }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return false
            }
        }
        return false
    }

    private static func postCommandV(to processID: pid_t) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = pasteKeyCode()
        guard
            let keyDown = CGEvent(
                keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(
                keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(processID)
        keyUp.postToPid(processID)
        return true
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
        guard let sourceID: CFString = currentInputSourceProperty(
            kTISPropertyInputSourceID,
            as: .string)
        else { return true }
        let qwertyCommandLayouts = [
            "DVORAK-QWERTY", "US", "ABC", "AUSTRALIAN", "BRITISH", "CANADIAN",
            "USINTERNATIONAL"
        ]
        let upper = (sourceID as String).uppercased()
        return qwertyCommandLayouts.contains { upper.contains($0) }
    }

    private static func keyCode(for character: Character) -> CGKeyCode? {
        guard let layoutData: CFData = currentInputSourceProperty(
            kTISPropertyUnicodeKeyLayoutData,
            as: .data)
        else { return nil }
        return keyCode(for: character, in: layoutData)
    }

    static func keyCode(
        for character: Character,
        in layoutData: CFData
    ) -> CGKeyCode? {
        guard CFDataGetLength(layoutData) >= MemoryLayout<UCKeyboardLayout>.size,
            let bytes = CFDataGetBytePtr(layoutData)
        else { return nil }
        let layout = UnsafeRawPointer(bytes)
            .assumingMemoryBound(to: UCKeyboardLayout.self)
        let target = character.lowercased()
        // Letter keys all live in the 0...50 virtual-keycode range.
        return withExtendedLifetime(layoutData) {
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

    /// TIS properties are borrowed, untyped C pointers. Promote the value to
    /// a strong Swift reference while the retained input source is alive, and
    /// reject a wrong-typed third-party property before any typed CF operation.
    private static func currentInputSourceProperty<Property: AnyObject>(
        _ key: CFString,
        as propertyType: BorrowedCFPropertyType<Property>
    ) -> Property? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return withExtendedLifetime(source) {
            typedUnretainedCFProperty(
                TISGetInputSourceProperty(source, key),
                as: propertyType)
        }
    }

    /// Accepts only CF object pointers supplied by APIs such as
    /// `TISGetInputSourceProperty`; the exact runtime type must still match.
    static func typedUnretainedCFProperty<Property: AnyObject>(
        _ pointer: UnsafeMutableRawPointer?,
        as propertyType: BorrowedCFPropertyType<Property>
    ) -> Property? {
        guard let pointer else { return nil }
        let value = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
        return checkedCFValue(value, as: propertyType)
    }

    static func checkedCFValue<Property: AnyObject>(
        _ value: CFTypeRef, as propertyType: BorrowedCFPropertyType<Property>
    ) -> Property? {
        guard CFGetTypeID(value) == propertyType.typeID else { return nil }
        return value as? Property
    }
}

extension TextInserter.BorrowedCFPropertyType where Value == CFString {
    static var string: Self { Self(typeID: CFStringGetTypeID()) }
}

extension TextInserter.BorrowedCFPropertyType where Value == CFData {
    static var data: Self { Self(typeID: CFDataGetTypeID()) }
}

extension TextInserter.BorrowedCFPropertyType where Value == AXUIElement {
    static var accessibilityElement: Self { Self(typeID: AXUIElementGetTypeID()) }
}

/// Full multi-type snapshot of the pasteboard. Saving only the plain string
/// (the previous behavior) silently destroyed rich content — an image, file
/// URLs, styled text — the moment a dictation landed.
struct PasteboardSnapshot {
    private let types: [NSPasteboard.PasteboardType]
    private let values: [NSPasteboard.PasteboardType: Value]
    let isComplete: Bool

    private enum Value {
        case data(Data)
        case string(String)
        case propertyList(Any)
    }

    init?(of pasteboard: NSPasteboard) {
        let types = pasteboard.types ?? []
        var capturedTypes: [NSPasteboard.PasteboardType] = []
        var values: [NSPasteboard.PasteboardType: Value] = [:]
        for type in types {
            if let data = pasteboard.data(forType: type) {
                values[type] = .data(data)
            } else if let string = pasteboard.string(forType: type) {
                values[type] = .string(string)
            } else if let list = pasteboard.propertyList(forType: type) {
                values[type] = .propertyList(list)
            } else {
                continue
            }
            capturedTypes.append(type)
        }
        guard !values.isEmpty else { return nil }
        self.types = capturedTypes
        self.values = values
        isComplete = capturedTypes.count == types.count
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
