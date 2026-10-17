import Foundation

/// The held-modifier trigger and whether it started the active session.
struct ModifierTriggerState {
    var ptt: ModifierKeyPTT?
    var setting = ModifierKeySetting.off
    var ownsSession = false
}

extension DictationController {
    /// Arms the held-modifier trigger to match Settings. It shares the mouse
    /// trigger's Accessibility trust and its retry when the app reactivates.
    func syncModifierPTT(services: AppServices, promptIfNeeded: Bool = false) {
        let enabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        let desired = enabled ? ModifierKeySetting.load() : .off
        if modifierTrigger.ptt != nil, modifierTrigger.setting == desired { return }
        // Rebinding while the modifier owns capture would strand its release.
        if modifierTrigger.ownsSession, isActive { cancel() }
        modifierTrigger.ptt?.invalidate()
        modifierTrigger.ptt = nil
        modifierTrigger.setting = .off
        guard !services.usesTemporaryMeetingStore, desired != .off else { return }
        if promptIfNeeded { _ = TextInserter.canInsert(promptIfNeeded: true) }
        guard let ptt = ModifierKeyPTT(
            setting: desired,
            onPress: { [weak self, weak services] in
                guard let self, let services else { return }
                handleModifier(.press, services: services)
            },
            onRelease: { [weak self, weak services] in
                guard let self, let services else { return }
                handleModifier(.release, services: services)
            },
            onChord: { [weak self] in
                // A shortcut typed while holding the key was never dictation.
                guard let self, modifierTrigger.ownsSession, isActive else { return }
                cancel()
            })
        else { return }
        modifierTrigger.ptt = ptt
        modifierTrigger.setting = desired
    }

    private func handleModifier(_ event: MousePTTGesture.Event, services: AppServices) {
        let owns = modifierTrigger.ownsSession
        switch MousePTTGesture.action(for: event, isListening: isActive, mouseOwnsSession: owns) {
        case .start:
            modifierTrigger.ownsSession = true
            start(services: services)
            if !isActive { modifierTrigger.ownsSession = false }
        case .finish:
            modifierTrigger.ownsSession = false
            finishAndInsert()
        case .ignore:
            break
        }
    }
}
