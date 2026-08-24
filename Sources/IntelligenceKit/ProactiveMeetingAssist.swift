import Foundation
import PortavozCore

/// One explicit user-authored objective that remains open in the current
/// recording. Proactive assistance receives no generated note or inferred
/// identity in this source lane.
public struct ProactiveAssistObjective: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String

    public init(id: UUID, text: String) {
        self.id = id
        self.text = text
    }
}

/// Stable, content-free identity for one proactive signal during a recording.
/// Once emitted, the same evidence authority cannot create repeated cards.
public enum ProactiveAssistSignalKey: Hashable, Sendable {
    case objective(UUID)
    case talkBalance
}

/// Exact finalized-caption authority behind a proactive suggestion.
public struct ProactiveAssistEvidence: Equatable, Sendable {
    public let meetingID: MeetingID
    public let segmentIDs: [UUID]
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let speechSeconds: TimeInterval

}

/// An inert local coaching card. It cannot invoke a model, Web request, or
/// external effect; presentation can only disclose or dismiss it.
public struct ProactiveAssistSuggestion: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case openObjective = "open-objective"
        case talkBalance = "talk-balance"
    }

    public let id: UUID
    public let kind: Kind
    public let signalKey: ProactiveAssistSignalKey
    public let evidence: ProactiveAssistEvidence
    public let objective: ProactiveAssistObjective?
    public let measuredUserFraction: Double?

    init(
        id: UUID = UUID(),
        kind: Kind,
        signalKey: ProactiveAssistSignalKey,
        evidence: ProactiveAssistEvidence,
        objective: ProactiveAssistObjective? = nil,
        measuredUserFraction: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.signalKey = signalKey
        self.evidence = evidence
        self.objective = objective
        self.measuredUserFraction = measuredUserFraction
    }
}

/// Pure admission for the two declared proactive signals in the 1.0 surface.
/// Work stays bounded by the newest finalized rows and produces at most one
/// candidate per evaluation.
public enum ProactiveMeetingAssistPolicy {
    public static let maximumSourceRows = 64
    public static let maximumVisibleSuggestions = 3
    public static let maximumObjectives = 8
    public static let maximumObjectiveCharacters = 280
    public static let maximumObjectiveUTF8Bytes = 2_048
    public static let maximumSourceCharacters = 4_000
    public static let maximumSourceUTF8Bytes = 16_384
    /// A defensive presentation bound, far beyond any practical meeting,
    /// keeps exact source timestamps representable by the macOS UI.
    public static let maximumTimelineOffset: TimeInterval = 1_000_000_000
    public static let minimumFinalizedTurns = 8
    public static let minimumConversationSpan: TimeInterval = 180
    public static let recentWindow: TimeInterval = 300
    public static let maximumSourceDuration: TimeInterval = recentWindow
    public static let minimumEmissionInterval: TimeInterval = 180
    public static let minimumTalkBalanceSpeech: TimeInterval = 60
    public static let notableUserFraction = 0.65

    public static func nextSuggestion(
        captions: [TranscriptSegment],
        pendingObjectives: [ProactiveAssistObjective],
        emittedSignals: Set<ProactiveAssistSignalKey>,
        lastEmissionOffset: TimeInterval?
    ) -> ProactiveAssistSuggestion? {
        guard let window = evidenceWindow(captions),
              objectivesAreValid(pendingObjectives),
              emissionIsDue(
                newestOffset: window.evidence.endTime,
                lastEmissionOffset: lastEmissionOffset)
        else { return nil }

        if window.rows.count >= minimumFinalizedTurns,
           window.evidence.endTime - window.evidence.startTime
            >= minimumConversationSpan,
           let objective = pendingObjectives.first(where: {
               !emittedSignals.contains(.objective($0.id))
           }) {
            return ProactiveAssistSuggestion(
                kind: .openObjective,
                signalKey: .objective(objective.id),
                evidence: window.evidence,
                objective: objective)
        }

        guard !emittedSignals.contains(.talkBalance),
              window.evidence.speechSeconds >= minimumTalkBalanceSpeech
        else { return nil }
        let userSpeech = window.rows.reduce(into: TimeInterval.zero) { total, row in
            guard row.channel == .microphone else { return }
            total += row.endTime - row.startTime
        }
        let fraction = userSpeech / window.evidence.speechSeconds
        guard fraction.isFinite, fraction >= notableUserFraction else { return nil }
        return ProactiveAssistSuggestion(
            kind: .talkBalance,
            signalKey: .talkBalance,
            evidence: window.evidence,
            measuredUserFraction: fraction)
    }

    private struct EvidenceWindow {
        let rows: [TranscriptSegment]
        let evidence: ProactiveAssistEvidence
    }

    private static func evidenceWindow(
        _ captions: [TranscriptSegment]
    ) -> EvidenceWindow? {
        guard let mutableTail = captions.last else { return nil }
        let boundedClosed = Array(captions.dropLast().suffix(maximumSourceRows))
        guard !boundedClosed.isEmpty,
              boundedClosed.allSatisfy(isValidFinalizedRow),
              rowsAreCanonical(boundedClosed),
              Set(boundedClosed.map(\.id)).count == boundedClosed.count,
              let meetingID = boundedClosed.first?.meetingID,
              boundedClosed.allSatisfy({ $0.meetingID == meetingID }),
              mutableTail.meetingID == meetingID,
              isValidSourceRow(mutableTail),
              !boundedClosed.contains(where: { $0.id == mutableTail.id }),
              let newest = boundedClosed.last,
              !TranscriptSegmentOrder.canonicalOrder(mutableTail, newest)
        else { return nil }

        let cutoff = newest.endTime - recentWindow
        let rows = boundedClosed.filter { $0.endTime >= cutoff }
        guard let first = rows.first, !rows.isEmpty else { return nil }
        let speechSeconds = rows.reduce(into: TimeInterval.zero) { total, row in
            total += row.endTime - row.startTime
        }
        guard speechSeconds.isFinite, speechSeconds > 0 else { return nil }
        return EvidenceWindow(
            rows: rows,
            evidence: ProactiveAssistEvidence(
                meetingID: meetingID,
                segmentIDs: rows.map(\.id),
                startTime: first.startTime,
                endTime: newest.endTime,
                speechSeconds: speechSeconds))
    }

    private static func isValidFinalizedRow(_ row: TranscriptSegment) -> Bool {
        row.isFinal && isValidSourceRow(row)
    }

    private static func isValidSourceRow(_ row: TranscriptSegment) -> Bool {
        let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return row.startTime.isFinite
            && row.endTime.isFinite
            && row.startTime >= 0
            && row.endTime >= row.startTime
            && row.endTime - row.startTime <= maximumSourceDuration
            && row.startTime <= maximumTimelineOffset
            && row.endTime <= maximumTimelineOffset
            && !text.isEmpty
            && text.count <= maximumSourceCharacters
            && text.utf8.count <= maximumSourceUTF8Bytes
    }

    private static func rowsAreCanonical(_ rows: [TranscriptSegment]) -> Bool {
        zip(rows, rows.dropFirst()).allSatisfy { first, second in
            !TranscriptSegmentOrder.canonicalOrder(second, first)
        }
    }

    private static func objectivesAreValid(
        _ objectives: [ProactiveAssistObjective]
    ) -> Bool {
        guard objectives.count <= maximumObjectives,
              Set(objectives.map(\.id)).count == objectives.count
        else { return false }
        return objectives.allSatisfy { objective in
            let text = objective.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty
                && text == objective.text
                && text.count <= maximumObjectiveCharacters
                && text.utf8.count <= maximumObjectiveUTF8Bytes
        }
    }

    private static func emissionIsDue(
        newestOffset: TimeInterval,
        lastEmissionOffset: TimeInterval?
    ) -> Bool {
        guard let lastEmissionOffset else { return true }
        guard lastEmissionOffset.isFinite, lastEmissionOffset >= 0 else { return false }
        return newestOffset - lastEmissionOffset >= minimumEmissionInterval
    }
}
