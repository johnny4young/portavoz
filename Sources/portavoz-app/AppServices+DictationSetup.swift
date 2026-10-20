import ApplicationServices

extension AppServices {
    /// Registers or retires every dictation trigger after the enable switch
    /// changes, from Settings or onboarding.
    func applyDictationEnabled(_ enabled: Bool) {
        dictation.syncHotkey(services: self)
        syncPasteLastShortcut()
        dictation.syncMousePTT(services: self, promptIfNeeded: enabled)
        dictation.syncModifierPTT(services: self, promptIfNeeded: enabled)
        prewarmDictationIfConfigured()
        if enabled { Task { await prepareSpeechGateIfEnabled() } }
    }

    /// Disposable launches report a fixed state and never show the system prompt.
    var dictationAccessibilityGranted: Bool {
        usesTemporaryMeetingStore ? false : AXIsProcessTrusted()
    }

    func requestDictationAccessibility() {
        guard !usesTemporaryMeetingStore else { return }
        _ = TextInserter.canInsert(promptIfNeeded: true)
    }
}
