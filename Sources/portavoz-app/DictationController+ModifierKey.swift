import Foundation

/// The held-modifier trigger and whether it started the active session.
struct ModifierTriggerState {
    var ptt: ModifierKeyPTT?
    var setting = ModifierKeySetting.off
    var ownsSession = false
    /// Selected but the event tap could not be created, usually missing Accessibility.
    var unavailable = false
}

extension DictationController {
    /// Arms the held-modifier trigger to match Settings. It shares the mouse
    /// trigger's Accessibility trust and its retry when the app reactivates.
    func syncModifierPTT(services: AppServices, promptIfNeeded: Bool = false) {
        let enabled = services.dictationTriggersMayArm && UserDefaults.standard.bool(forKey: Self.defaultsKey)
        let desired = enabled ? ModifierKeySetting.load() : .off
        if modifierTrigger.ptt != nil, modifierTrigger.setting == desired { return }
        // Rebinding while the modifier owns capture would strand its release.
        if modifierTrigger.ownsSession, isActive, !yieldsToHandoff { cancel() }
        modifierTrigger.ptt?.invalidate()
        modifierTrigger.ptt = nil
        modifierTrigger.setting = .off
        modifierTrigger.unavailable = false
        guard !services.usesTemporaryMeetingStore, desired != .off else { return }
        if promptIfNeeded { _ = TextInserter.canInsert(promptIfNeeded: true) }
        guard let ptt = ModifierKeyPTT(
            setting: desired,
            // Admission does file I/O, so it leaves the event tap callback.
            onPress: { [weak self, weak services] in
                DispatchQueue.main.async {
                    guard let self, let services else { return }
                    self.handleModifier(.press) { self.start(services: services) }
                }
            },
            onRelease: { [weak self, weak services] in
                DispatchQueue.main.async {
                    guard let self, let services else { return }
                    self.handleModifier(.release) { self.start(services: services) }
                }
            },
            onChord: { [weak self] in
                DispatchQueue.main.async {
                    // A shortcut typed while holding the key was never dictation.
                    guard let self, self.modifierTrigger.ownsSession, self.isActive else { return }
                    self.cancel()
                }
            })
        else {
            modifierTrigger.unavailable = true
            return
        }
        modifierTrigger.ptt = ptt
        modifierTrigger.setting = desired
    }

    func handleModifier(_ event: MousePTTGesture.Event, start beginSession: () -> Void) {
        let owns = modifierTrigger.ownsSession
        // A held key controls only the dictation it started; Fn shortcuts typed
        // during a tap- or hotkey-started session must not end it.
        if isActive, !owns { return }
        switch MousePTTGesture.action(for: event, isListening: isActive, mouseOwnsSession: owns) {
        case .start:
            modifierTrigger.ownsSession = true
            beginSession()
            if !isActive { modifierTrigger.ownsSession = false }
        case .finish:
            modifierTrigger.ownsSession = false
            finishAndInsert()
        case .ignore:
            break
        }
    }
}
