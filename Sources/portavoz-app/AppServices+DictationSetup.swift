import ApplicationServices
import Foundation
import PortavozCore

extension AppServices {
    /// Registers or retires every dictation trigger after the enable switch
    /// changes, from Settings or onboarding.
    func applyDictationEnabled(_ enabled: Bool) {
        dictation.syncHotkey(services: self)
        syncPasteLastShortcut()
        syncRewriteSelectionShortcut()
        dictation.syncMousePTT(services: self, promptIfNeeded: enabled)
        dictation.syncModifierPTT(services: self, promptIfNeeded: enabled)
        prewarmDictationIfConfigured()
        if enabled { Task { await prepareSpeechGateIfEnabled() } }
    }

    /// Disposable launches can start with history on, optionally with two saved rows.
    func loadDictationHistory() async {
        await dictationHistory.load()
        let arguments = ProcessInfo.processInfo.arguments
        guard usesTemporaryMeetingStore, arguments.contains("-seed-dictation-history") else { return }
        let seedsRecords = arguments.contains("-seed-dictation-history-records")
        await dictationHistory.update(isEnabled: true, keepsOriginal: seedsRecords)
        defer { simulateOpenDictationsIntentIfRequested(arguments) }
        guard seedsRecords, let write = dictationHistory.admit() else { return }
        let now = Date()
        for (offset, sample) in [
            ("Send the report on Friday.", nil, "Slack", DictationRecordDelivery.notDelivered),
            ("No borres estas notas.", "eh no borres estas notas", "Notes", .verified)
        ].enumerated() {
            _ = await write(DictationRecord(
                id: DictationRecordID(), createdAt: now.addingTimeInterval(Double(offset - 2) * 60), duration: 3,
                text: sample.0, originalText: sample.1, mode: sample.1 == nil ? .literal : .clean, language: nil,
                engine: "parakeet", applicationName: sample.2, applicationBundleID: nil, delivery: sample.3))
        }
    }

    /// XCUITest-only: the Open dictations Shortcut's request, through the same bridge.
    private func simulateOpenDictationsIntentIfRequested(_ arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "-simulate-open-dictations-intent"),
              arguments.indices.contains(flag + 1)
        else { return }
        PortavozAppIntentBridge.requestNavigation(.dictations(arguments[flag + 1]))
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
