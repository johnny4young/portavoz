import Foundation

extension RecordingController {
    /// A SwiftUI Translation task owns exactly one explicit source→target
    /// pair. Moving to another actor language resets download consent so a
    /// new language pack is never fetched because of an earlier pair.
    func beginLiveTranslationPair(_ pair: LiveTranslationPair) {
        guard translationTarget == pair.target else { return }
        guard translationSource != pair.source else { return }
        translationSource = pair.source
        translationDownloadApproved = false
        liveTranslationWakeHub.signal()
    }

    /// LiveTranslation can publish only finite user-facing state, never
    /// framework errors or transcript content as diagnostics.
    func updateLiveTranslationState(_ state: LiveTranslationState) {
        guard translationTarget != nil || state == .off else { return }
        translationState = presentedLiveTranslationState(state)
    }

    /// Old Translation tasks can complete after SwiftUI cancels them. Admit a
    /// state transition only when it still owns the selected source→target
    /// lane; checking only the target lets a stale Spanish task overwrite the
    /// state of a newer French task that translates to the same language.
    func updateLiveTranslationState(
        _ state: LiveTranslationState,
        for pair: LiveTranslationPair
    ) {
        guard translationTarget == pair.target,
            translationSource == pair.source
        else { return }
        translationState = presentedLiveTranslationState(state)
    }

    /// Unsupported rows are passthrough, not terminal work. Recording their
    /// IDs lets routing advance while preserving one honest partial-support
    /// explanation after supported lanes succeed.
    func markUnsupportedLiveTranslationRows(
        _ ids: Set<UUID>,
        for pair: LiveTranslationPair
    ) {
        guard translationTarget == pair.target,
            translationSource == pair.source,
            !ids.isEmpty
        else { return }
        unsupportedTranslationRowIDs.formUnion(ids)
        hasUnsupportedTranslationRows = true
        translationState = .partiallyUnsupported
        liveTranslationWakeHub.signal()
    }

    /// Prevents a canceled old-language task from repopulating rendered rows
    /// after either side of the selected language lane has changed.
    @discardableResult
    func storeLiveTranslations(
        _ values: [UUID: String],
        sourceTexts: [UUID: String] = [:],
        for pair: LiveTranslationPair
    ) -> Bool {
        guard translationTarget == pair.target,
            translationSource == pair.source
        else { return false }
        translations.merge(values) { _, new in new }
        translatedSourceTexts.merge(sourceTexts) { _, new in new }
        return !values.isEmpty
    }

    private func presentedLiveTranslationState(
        _ state: LiveTranslationState
    ) -> LiveTranslationState {
        guard hasUnsupportedTranslationRows else { return state }
        switch state {
        case .ready, .active, .unsupported:
            return .partiallyUnsupported
        case .off, .waitingForTranscript, .needsDownload, .translating,
            .partiallyUnsupported, .failed:
            return state
        }
    }
}
