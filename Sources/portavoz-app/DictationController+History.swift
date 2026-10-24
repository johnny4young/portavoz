import Foundation
import Observation
import PortavozCore

/// Saves one dictation, admitted with the consent generation read when it started.
typealias DictationHistoryWriter = @MainActor (DictationRecord) async -> Bool

/// The history entry of one session. It exists only when history was on at start.
@MainActor
@Observable
final class DictationHistorySession {
    enum State: Equatable {
        case pending
        case saving
        case saved
        case failed
        /// Never saved: a secure field, an empty or cancelled delivery.
        case skipped
    }

    let sessionID: UUID
    private(set) var state = State.pending
    @ObservationIgnored private let write: DictationHistoryWriter
    @ObservationIgnored private var draft: DictationRecord?

    init(sessionID: UUID, write: @escaping DictationHistoryWriter) {
        self.sessionID = sessionID
        self.write = write
    }

    func prepare(_ draft: DictationRecord) {
        self.draft = draft
    }

    /// A retry of the same dictation updates its delivery instead of adding a row.
    func record(_ result: DictationDeliveryOutcome) {
        guard let draft, let delivery = Self.delivery(for: result) else {
            if state == .pending { state = .skipped }
            return
        }
        state = .saving
        let write = write
        Task { @MainActor [weak self] in
            let saved = await write(draft.with(delivery: delivery))
            self?.state = saved ? .saved : .failed
        }
    }

    static func delivery(for result: DictationDeliveryOutcome) -> DictationRecordDelivery? {
        switch result {
        case .verified: .verified
        case .dispatched: .dispatched
        case .refused(.secureField), .refused(.emptyText), .refused(.cancelled): nil
        case .refused: .notDelivered
        }
    }
}

extension DictationController {
    /// Also prepares the statistics, which count a session without its text.
    func prepareHistory(original: String, text: String, dependencies: DictationSessionDependencies) {
        if let sessionID = activeSessionID {
            prepareStats(text: text, sessionID: sessionID, dependencies: dependencies)
        }
        guard let history else { return }
        let now = dependencies.now()
        let startedAt = captureStartedAt ?? now
        history.prepare(DictationRecord(
            id: DictationRecordID(rawValue: history.sessionID),
            createdAt: startedAt,
            duration: max(0, now.timeIntervalSince(startedAt)),
            text: text,
            originalText: original,
            mode: textMode,
            language: dependencies.transcriptionHints().language,
            engine: LiveSpeechPurpose.dictation.selectedEngine(in: dependencies.defaults).rawValue,
            applicationName: destination?.name,
            applicationBundleID: destination?.bundleIdentifier,
            delivery: .notDelivered))
    }

    func recordHistory(_ result: DictationDeliveryOutcome, id: UUID) {
        recordStats(result, id: id)
        guard let history, history.sessionID == id else { return }
        history.record(result)
    }

    /// What Portavoz kept of the delivery the panel shows.
    var deliveryPrivacyLine: String {
        guard let history, history.sessionID == deliveryID else { return L10n.text("Nothing was saved in Portavoz.") }
        return switch history.state {
        case .pending, .skipped: L10n.text("Nothing was saved in Portavoz.")
        case .saving: L10n.text("Saving to your dictation history…")
        case .saved: L10n.text("Saved to your dictation history.")
        case .failed: L10n.text("Not saved to your dictation history.")
        }
    }
}
