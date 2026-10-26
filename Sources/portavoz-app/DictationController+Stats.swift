import Foundation
import PortavozCore

/// What the statistics keep of one session until its delivery settles.
struct DictationStatsDraft {
    let sessionID: UUID
    let startedAt: Date
    let spokenDuration: TimeInterval
    var words: Int
    let applicationName: String?
    let record: (DictationStatsSample) -> Void
}

extension DictationController {
    func prepareStats(text: String, sessionID: UUID, dependencies: DictationSessionDependencies) {
        let now = dependencies.now()
        let startedAt = captureStartedAt ?? now
        statsDraft = DictationStatsDraft(
            sessionID: sessionID, startedAt: startedAt, spokenDuration: max(0, now.timeIntervalSince(startedAt)),
            words: DictationStatsCalendar.wordCount(text), applicationName: destination?.name,
            record: dependencies.recordStats)
    }

    /// Counted like the history: secure fields, empty and cancelled deliveries never are.
    /// A retry of the same session updates its delivery instead of counting again.
    func recordStats(_ result: DictationDeliveryOutcome, id: UUID, calendar: Calendar = .current) {
        guard let draft = statsDraft, draft.sessionID == id,
              let delivery = DictationHistorySession.delivery(for: result)
        else { return }
        draft.record(DictationStatsSample(
            id: DictationRecordID(rawValue: id),
            day: DictationStatsCalendar.day(of: draft.startedAt, calendar: calendar),
            words: draft.words, spokenDuration: draft.spokenDuration, applicationName: draft.applicationName,
            delivered: delivery != .notDelivered))
    }
}
