import Foundation

extension DictationController {
    /// Re-register the configured hotkey after either Settings value changes.
    func syncHotkey(services: AppServices) {
        if !UserDefaults.standard.bool(forKey: Self.defaultsKey), isActive, phase != .delivering {
            cancel()
        }
        shortcut.sync(
            registrar: services.dictationShortcutRegistrar,
            onPress: { [weak self, weak services] in
                guard let self, let services else { return }
                self.handleHotkeyPress(using: services.makeDictationSessionDependencies(), at: Date())
            },
            onRelease: { [weak self] in
                guard let self else { return }
                self.handleHotkeyRelease(at: Date())
            })
    }

    func handleHotkeyPress(using dependencies: DictationSessionDependencies, at now: Date) {
        let wasActive = isActive
        toggle(using: dependencies)
        // Only a press that actually began this session can later finish it
        // on release. A second press remains the recovery for a lost key-up.
        if !wasActive, isActive {
            pressedAt = now
            pressedSessionID = activeSessionID
        } else {
            pressedAt = nil
            pressedSessionID = nil
        }
    }

    func handleHotkeyRelease(at now: Date) {
        let ownsSession = activeSessionID != nil && pressedSessionID == activeSessionID
        let heldLongEnough = pressedAt.map { now.timeIntervalSince($0) > Self.holdThreshold } ?? false
        pressedAt = nil
        pressedSessionID = nil
        guard ownsSession, isActive, heldLongEnough else { return }
        finishAndInsert()
    }
}
