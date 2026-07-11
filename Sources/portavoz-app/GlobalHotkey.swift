import Carbon.HIToolbox
import Foundation

/// A single system-wide hotkey via Carbon's `RegisterEventHotKey` — the
/// one macOS API that both works WITHOUT the Accessibility permission and
/// consumes the keystroke (an `NSEvent` global monitor needs the
/// permission and only observes). Carbon delivers the event on the main
/// thread, so the callback hops straight into the main actor.
@MainActor
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void
    private let onRelease: () -> Void

    /// - Parameters:
    ///   - keyCode: a `kVK_*` virtual key code (e.g. `kVK_ANSI_D`).
    ///   - modifiers: Carbon modifier mask (e.g. `optionKey | cmdKey`).
    ///   - onRelease: fired when the combo is let go — the hold-to-talk
    ///     half of the gesture (Carbon delivers kEventHotKeyReleased).
    init?(
        keyCode: UInt32,
        modifiers: UInt32,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void = {}
    ) {
        self.onPress = onPress
        self.onRelease = onRelease

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                let kind = GetEventKind(event)
                // Carbon dispatches on the main thread.
                MainActor.assumeIsolated {
                    kind == UInt32(kEventHotKeyReleased) ? hotkey.onRelease() : hotkey.onPress()
                }
                return noErr
            },
            2, &eventTypes, selfPointer, &handlerRef)
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5056_4F5A), id: 1)  // "PVOZ"
        let registerStatus = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            RemoveEventHandler(handlerRef)
            handlerRef = nil
            return nil
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    // No deinit cleanup: a nonisolated deinit cannot touch the main-actor
    // Carbon refs under Swift 6. Owners call `unregister()` — in this app
    // the hotkey lives in `DictationController` for the process lifetime,
    // so a leaked registration is impossible in practice.
}
