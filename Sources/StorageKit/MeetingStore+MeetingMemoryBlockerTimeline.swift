import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    struct BlockerTimelineCandidate {
        let id: UUID
        let kind: MeetingMemoryTimelineItemKind
        let change: MeetingMemoryTimelineBlockerChange
        let evidence: DecisionCommitmentBlockerEvidence
        let occurredAt: Date
    }

    static func appendDecisionCommitmentBlockerTimelineItems(
        subject: MeetingMemoryTimelineSubject,
        through: MeetingMemoryTimelineMeeting,
        candidateLimit: Int,
        accumulator: inout TimelineAccumulator,
        in database: Database
    ) throws {
        let keys = try timelineBlockerKeys(
            subject: subject,
            throughMeetingID: through.id,
            candidateLimit: candidateLimit,
            in: database)
        if keys.count > candidateLimit {
            accumulator.candidateOverflow = true
        }
        for key in keys.prefix(candidateLimit) {
            let blockerID = DecisionCommitmentBlockerID(
                rawValue: try requiredTimelineUUID(key))
            let continuity = try loadDecisionCommitmentBlockerContinuity(
                blockerID,
                in: database)
            try appendBlockerContinuity(
                continuity,
                throughMeetingID: through.id,
                accumulator: &accumulator,
                in: database)
        }
    }

    static func appendBlockerContinuity(
        _ continuity: DecisionCommitmentBlockerContinuity,
        throughMeetingID: MeetingID,
        accumulator: inout TimelineAccumulator,
        in database: Database
    ) throws {
        let decision = try loadDecisionContinuity(
            continuity.blocker.decisionID,
            in: database)
        let commitment = try loadCommitmentContinuity(
            continuity.blocker.commitmentID,
            in: database)
        if continuity.openingEvidence.meetingID == throughMeetingID {
            try appendBlockerTimelineItem(
                BlockerTimelineCandidate(
                    id: continuity.blocker.id.rawValue,
                    kind: .commitmentBlocked,
                    change: .blocked,
                    evidence: continuity.openingEvidence,
                    occurredAt: continuity.blocker.confirmedAt),
                continuity: continuity,
                decisionText: decision.decision.statement,
                commitmentText: commitment.commitment.title,
                accumulator: &accumulator,
                in: database)
        }
        for event in continuity.events where event.evidence.meetingID == throughMeetingID {
            try appendBlockerTimelineItem(
                blockerTimelineCandidate(event),
                continuity: continuity,
                decisionText: decision.decision.statement,
                commitmentText: commitment.commitment.title,
                accumulator: &accumulator,
                in: database)
        }
    }

    static func appendBlockerTimelineItem(
        _ candidate: BlockerTimelineCandidate,
        continuity: DecisionCommitmentBlockerContinuity,
        decisionText: String,
        commitmentText: String,
        accumulator: inout TimelineAccumulator,
        in database: Database
    ) throws {
        switch try timelineEvidence(for: candidate.evidence, in: database) {
        case .current(let evidence):
            accumulator.items.append(MeetingMemoryTimelineItem(
                id: candidate.id,
                kind: candidate.kind,
                entity: .commitment(continuity.blocker.commitmentID),
                relatedEntity: .decision(continuity.blocker.decisionID),
                text: commitmentText,
                relatedText: decisionText,
                blockerChange: candidate.change,
                origin: .confirmed,
                occurredAt: candidate.occurredAt,
                evidence: evidence))
        case .stale:
            accumulator.omit(.stale)
        case .unavailable:
            accumulator.omit(.unavailable)
        }
    }

    static func blockerTimelineCandidate(
        _ event: DecisionCommitmentBlockerEvent
    ) -> BlockerTimelineCandidate {
        switch event.kind {
        case .clear:
            BlockerTimelineCandidate(
                id: event.id.rawValue,
                kind: .commitmentUnblocked,
                change: .cleared,
                evidence: event.evidence,
                occurredAt: event.occurredAt)
        case .reopen:
            BlockerTimelineCandidate(
                id: event.id.rawValue,
                kind: .commitmentBlockerReopened,
                change: .reopened,
                evidence: event.evidence,
                occurredAt: event.occurredAt)
        }
    }

    static func timelineBlockerKeys(
        subject: MeetingMemoryTimelineSubject,
        throughMeetingID: MeetingID,
        candidateLimit: Int,
        in database: Database
    ) throws -> [String] {
        let throughKey = throughMeetingID.rawValue.uuidString
        switch subject {
        case .topic:
            return try String.fetchAll(
                database,
                sql: """
                    SELECT blockerID
                    FROM meetingMemoryGraphMeetingBlocker
                    WHERE meetingID = ?
                    ORDER BY blockerID
                    LIMIT ?
                    """,
                arguments: [throughKey, candidateLimit + 1])
        case .person(let personID):
            return try String.fetchAll(
                database,
                sql: """
                    SELECT blocker.blockerID
                    FROM meetingMemoryGraphMeetingBlocker AS meeting
                    JOIN meetingMemoryGraphDecisionCommitmentBlocker AS blocker
                      ON blocker.blockerID = meeting.blockerID
                    JOIN meetingMemoryGraphCommitmentPerson AS owner
                      ON owner.commitmentID = blocker.commitmentID
                    WHERE meeting.meetingID = ?
                      AND owner.personID = ?
                    ORDER BY blocker.blockerID
                    LIMIT ?
                    """,
                arguments: [
                    throughKey,
                    personID.rawValue.uuidString,
                    candidateLimit + 1
                ])
        }
    }
}
