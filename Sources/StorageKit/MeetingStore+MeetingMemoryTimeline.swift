import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Reads one bounded, correction-aware "since last time" page. The graph
    /// supplies disposable topology only; every returned item is rehydrated
    /// from current confirmed authority and exact accepted transcript rows in
    /// the same SQLite snapshot.
    public func meetingMemoryTimeline(
        _ query: MeetingMemoryTimelineQuery
    ) async throws -> MeetingMemoryTimelineResult {
        guard query.isValid else { return .abstained(.invalidQuery) }
        return try await database.read { database in
            try Self.loadMeetingMemoryTimeline(query, in: database)
        }
    }

    static func loadMeetingMemoryTimeline(
        _ query: MeetingMemoryTimelineQuery,
        in database: Database
    ) throws -> MeetingMemoryTimelineResult {
        guard query.isValid else { return .abstained(.invalidQuery) }
        guard try meetingMemoryGraphProjectionIsReady(in: database) else {
            return .abstained(.projectionNotReady)
        }
        guard let resolved = try resolvedTimelineSubject(
            query.subject,
            in: database
        ) else { return .abstained(.subjectUnavailable) }
        let relatedMeetings = try timelineMeetings(
            for: resolved.subject,
            subjectKey: resolved.key,
            in: database)
        guard !relatedMeetings.isEmpty else {
            return .abstained(.subjectUnavailable)
        }
        let window: TimelineWindow
        switch timelineWindow(
            among: relatedMeetings,
            throughMeetingID: query.throughMeetingID
        ) {
        case .ready(let value):
            window = value
        case .abstained(let reason):
            return .abstained(reason)
        }
        return try assembleMeetingMemoryTimeline(
            query: query,
            resolvedSubject: resolved.subject,
            window: window,
            in: database)
    }

    fileprivate static func assembleMeetingMemoryTimeline(
        query: MeetingMemoryTimelineQuery,
        resolvedSubject: MeetingMemoryTimelineSubject,
        window: TimelineWindow,
        in database: Database
    ) throws -> MeetingMemoryTimelineResult {
        let candidateLimit = min(
            MeetingMemoryTimelineQuery.maximumItemLimit * 8,
            max(32, query.itemLimit * 4))
        var accumulator = TimelineAccumulator()

        if case .topic = resolvedSubject {
            try appendDecisionTimelineItems(
                baseline: window.baseline,
                through: window.through,
                candidateLimit: candidateLimit,
                accumulator: &accumulator,
                in: database)
        }
        try appendCommitmentTimelineItems(
            subject: resolvedSubject,
            through: window.through,
            candidateLimit: candidateLimit,
            accumulator: &accumulator,
            in: database)

        accumulator.items.sort(by: timelineItemPrecedes)
        let hasMore = accumulator.candidateOverflow
            || accumulator.items.count > query.itemLimit
        let items = Array(accumulator.items.prefix(query.itemLimit))
        if items.isEmpty {
            if accumulator.unavailableCount > 0 {
                return .abstained(.evidenceUnavailable)
            }
            if accumulator.staleCount > 0 {
                return .abstained(.staleEvidenceOnly)
            }
        }

        let generation = try Int.fetchOne(
            database,
            sql: """
                SELECT sourceGeneration
                FROM meetingMemoryGraphProjectionState
                WHERE id = 'current'
                """) ?? 0
        let unsupportedKinds = MeetingMemoryTimelineItemKind.allCases.filter {
            $0 == .unresolvedQuestion || accumulator.unsupportedKinds.contains($0)
        }
        return .timeline(MeetingMemoryTimelinePage(
            subject: resolvedSubject,
            baseline: window.baseline,
            through: window.through,
            items: items,
            hasMore: hasMore,
            projectionGeneration: generation,
            omittedStaleCount: accumulator.staleCount,
            omittedUnavailableCount: accumulator.unavailableCount,
            unsupportedKinds: unsupportedKinds))
    }
}

private extension MeetingStore {
    struct TimelineResolvedSubject {
        let subject: MeetingMemoryTimelineSubject
        let key: String
    }

    struct TimelineWindow {
        let baseline: MeetingMemoryTimelineMeeting
        let through: MeetingMemoryTimelineMeeting
    }

    enum TimelineWindowResolution {
        case ready(TimelineWindow)
        case abstained(MeetingMemoryTimelineAbstentionReason)
    }

    struct TimelineAccumulator {
        var items: [MeetingMemoryTimelineItem] = []
        var candidateOverflow = false
        var staleCount = 0
        var unavailableCount = 0
        var unsupportedKinds: Set<MeetingMemoryTimelineItemKind> = []

        mutating func omit(_ status: TimelineEvidenceStatus) {
            switch status {
            case .current: break
            case .stale: staleCount += 1
            case .unavailable: unavailableCount += 1
            }
        }
    }

    enum TimelineEvidenceStatus {
        case current([MeetingMemoryTimelineEvidence])
        case stale
        case unavailable
    }

    static func resolvedTimelineSubject(
        _ subject: MeetingMemoryTimelineSubject,
        in database: Database
    ) throws -> TimelineResolvedSubject? {
        switch subject {
        case .person(let personID):
            guard let person = try PersonRecord.fetchOne(
                database,
                key: personID.rawValue.uuidString),
                  person.deletedAt == nil
            else { return nil }
            return TimelineResolvedSubject(subject: .person(personID), key: person.id)
        case .topic(let topicID):
            let topics = try liveTopicRecords(in: database)
            guard topics[topicID.rawValue.uuidString] != nil else { return nil }
            let root = try topicRoot(topicID.rawValue.uuidString, among: topics)
            let rootID = TopicID(rawValue: try requiredTimelineUUID(root.id))
            return TimelineResolvedSubject(subject: .topic(rootID), key: root.id)
        }
    }

    static func timelineWindow(
        among meetings: [MeetingMemoryTimelineMeeting],
        throughMeetingID: MeetingID?
    ) -> TimelineWindowResolution {
        let throughIndex: Int
        if let throughMeetingID {
            guard let index = meetings.firstIndex(where: {
                $0.id == throughMeetingID
            }) else { return .abstained(.anchorNotRelated) }
            throughIndex = index
        } else {
            throughIndex = meetings.index(before: meetings.endIndex)
        }
        guard throughIndex > meetings.startIndex else {
            return .abstained(.missingTemporalBaseline)
        }
        return .ready(TimelineWindow(
            baseline: meetings[meetings.index(before: throughIndex)],
            through: meetings[throughIndex]))
    }

    static func timelineMeetings(
        for subject: MeetingMemoryTimelineSubject,
        subjectKey: String,
        in database: Database
    ) throws -> [MeetingMemoryTimelineMeeting] {
        let rows: [Row]
        switch subject {
        case .topic:
            rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT meeting.id, meeting.title, meeting.startedAt
                    FROM meetingMemoryGraphMeetingTopic AS edge
                    JOIN meeting ON meeting.id = edge.meetingID
                    WHERE edge.topicID = ?
                      AND meeting.deletedAt IS NULL
                    ORDER BY meeting.startedAt, meeting.id
                    """,
                arguments: [subjectKey])
        case .person:
            rows = try Row.fetchAll(
                database,
                sql: """
                    WITH related(meetingID) AS (
                        SELECT meetingID
                        FROM meetingMemoryGraphMeetingPerson
                        WHERE personID = ?
                        UNION
                        SELECT meetingEdge.meetingID
                        FROM meetingMemoryGraphCommitmentPerson AS ownerEdge
                        JOIN meetingMemoryGraphMeetingCommitment AS meetingEdge
                          ON meetingEdge.commitmentID = ownerEdge.commitmentID
                        WHERE ownerEdge.personID = ?
                        UNION
                        SELECT event.sourceMeetingID
                        FROM meetingMemoryGraphCommitmentPerson AS ownerEdge
                        JOIN commitmentEvent AS event
                          ON event.commitmentID = ownerEdge.commitmentID
                        WHERE ownerEdge.personID = ?
                          AND event.sourceMeetingID IS NOT NULL
                    )
                    SELECT meeting.id, meeting.title, meeting.startedAt
                    FROM related
                    JOIN meeting ON meeting.id = related.meetingID
                    WHERE meeting.deletedAt IS NULL
                    ORDER BY meeting.startedAt, meeting.id
                    """,
                arguments: [subjectKey, subjectKey, subjectKey])
        }
        return try rows.map { row in
            MeetingMemoryTimelineMeeting(
                id: MeetingID(rawValue: try requiredTimelineUUID(row["id"])),
                title: row["title"],
                startedAt: row["startedAt"])
        }
    }

    static func appendDecisionTimelineItems(
        baseline: MeetingMemoryTimelineMeeting,
        through: MeetingMemoryTimelineMeeting,
        candidateLimit: Int,
        accumulator: inout TimelineAccumulator,
        in database: Database
    ) throws {
        let fetchedDecisionKeys = try String.fetchAll(
            database,
            sql: """
                SELECT DISTINCT decisionID
                FROM meetingMemoryGraphMeetingDecision
                WHERE meetingID IN (?, ?)
                ORDER BY decisionID
                LIMIT ?
                """,
            arguments: [
                baseline.id.rawValue.uuidString,
                through.id.rawValue.uuidString,
                candidateLimit + 1
            ])
        if fetchedDecisionKeys.count > candidateLimit {
            accumulator.candidateOverflow = true
        }
        let decisionKeys = fetchedDecisionKeys.prefix(candidateLimit)
        for decisionKey in decisionKeys {
            let decisionID = DecisionID(rawValue: try requiredTimelineUUID(decisionKey))
            let continuity = try loadDecisionContinuity(decisionID, in: database)
            for event in continuity.events {
                try appendDecisionTimelineItem(
                    event: event,
                    continuity: continuity,
                    baseline: baseline,
                    through: through,
                    accumulator: &accumulator,
                    in: database)
            }
        }
    }

    static func appendDecisionTimelineItem(
        event: DecisionEvent,
        continuity: DecisionContinuity,
        baseline: MeetingMemoryTimelineMeeting,
        through: MeetingMemoryTimelineMeeting,
        accumulator: inout TimelineAccumulator,
        in database: Database
    ) throws {
        switch event.kind {
        case .confirm:
            try appendConfirmedDecisionTimelineItem(
                event: event,
                continuity: continuity,
                through: through,
                accumulator: &accumulator,
                in: database)
        case .supersede, .reverse:
            try appendDecisionRelationshipTimelineItem(
                event: event,
                continuity: continuity,
                baseline: baseline,
                through: through,
                accumulator: &accumulator,
                in: database)
        }
    }

    static func appendConfirmedDecisionTimelineItem(
        event: DecisionEvent,
        continuity: DecisionContinuity,
        through: MeetingMemoryTimelineMeeting,
        accumulator: inout TimelineAccumulator,
        in database: Database
    ) throws {
        guard let sourceID = event.sourceID,
              let source = continuity.sources.first(where: {
                  $0.id == sourceID && $0.meetingID == through.id
              })
        else { return }
        switch try timelineEvidence(for: source, in: database) {
        case .current(let evidence):
            accumulator.items.append(MeetingMemoryTimelineItem(
                id: event.id.rawValue,
                kind: .decisionConfirmed,
                entity: .decision(continuity.decision.id),
                text: continuity.decision.statement,
                origin: .confirmed,
                occurredAt: event.occurredAt,
                evidence: evidence))
        case .stale:
            accumulator.omit(.stale)
        case .unavailable:
            accumulator.omit(.unavailable)
        }
    }

    static func appendDecisionRelationshipTimelineItem(
        event: DecisionEvent,
        continuity: DecisionContinuity,
        baseline: MeetingMemoryTimelineMeeting,
        through: MeetingMemoryTimelineMeeting,
        accumulator: inout TimelineAccumulator,
        in database: Database
    ) throws {
        guard let successorID = event.relatedDecisionID else { return }
        let successor = try loadDecisionContinuity(successorID, in: database)
        let priorEvidence = try timelineEvidence(
            for: continuity.sources,
            meetingID: baseline.id,
            in: database)
        let successorEvidence = try timelineEvidence(
            for: successor.sources,
            meetingID: through.id,
            in: database)
        guard case .current(let oldEvidence) = priorEvidence,
              case .current(let newEvidence) = successorEvidence
        else {
            accumulator.omit(combinedEvidenceStatus(priorEvidence, successorEvidence))
            return
        }
        accumulator.items.append(MeetingMemoryTimelineItem(
            id: event.id.rawValue,
            kind: event.kind == .supersede
                ? .decisionSuperseded
                : .decisionReversed,
            entity: .decision(continuity.decision.id),
            relatedEntity: .decision(successor.decision.id),
            text: continuity.decision.statement,
            relatedText: successor.decision.statement,
            origin: .confirmed,
            occurredAt: event.occurredAt,
            evidence: oldEvidence + newEvidence))
    }

    static func appendCommitmentTimelineItems(
        subject: MeetingMemoryTimelineSubject,
        through: MeetingMemoryTimelineMeeting,
        candidateLimit: Int,
        accumulator: inout TimelineAccumulator,
        in database: Database
    ) throws {
        let fetchedCommitmentKeys = try timelineCommitmentKeys(
            subject: subject,
            throughMeetingID: through.id,
            candidateLimit: candidateLimit,
            in: database)
        if fetchedCommitmentKeys.count > candidateLimit {
            accumulator.candidateOverflow = true
        }
        let commitmentKeys = fetchedCommitmentKeys.prefix(candidateLimit)
        for commitmentKey in commitmentKeys {
            let commitmentID = CommitmentID(
                rawValue: try requiredTimelineUUID(commitmentKey))
            let continuity = try loadCommitmentContinuity(commitmentID, in: database)
            for event in continuity.events where event.sourceMeetingID == through.id {
                if event.kind == .confirm {
                    try appendCommitmentConfirmationTimelineItem(
                        event: event,
                        continuity: continuity,
                        through: through,
                        accumulator: &accumulator,
                        in: database)
                } else {
                    try appendCommitmentChangeTimelineItem(
                        event: event,
                        continuity: continuity,
                        accumulator: &accumulator,
                        in: database)
                }
            }
        }
    }

    static func appendCommitmentChangeTimelineItem(
        event: CommitmentEvent,
        continuity: CommitmentContinuityEnvelope,
        accumulator: inout TimelineAccumulator,
        in database: Database
    ) throws {
        guard let source = event.evidence else {
            accumulator.unsupportedKinds.insert(timelineKind(for: event.kind))
            return
        }
        switch try timelineEvidence(for: source, in: database) {
        case .current(let evidence):
            accumulator.items.append(MeetingMemoryTimelineItem(
                id: event.id.rawValue,
                kind: timelineKind(for: event.kind),
                entity: .commitment(continuity.commitment.id),
                text: continuity.commitment.title,
                commitmentChange: timelineChange(for: event),
                origin: .confirmed,
                occurredAt: event.occurredAt,
                evidence: evidence))
        case .stale:
            accumulator.omit(.stale)
        case .unavailable:
            accumulator.omit(.unavailable)
        }
    }

    static func timelineKind(
        for eventKind: CommitmentEventKind
    ) -> MeetingMemoryTimelineItemKind {
        switch eventKind {
        case .confirm: .commitmentConfirmed
        case .reassign: .commitmentReassigned
        case .reschedule: .commitmentRescheduled
        case .complete: .commitmentCompleted
        case .reopen: .commitmentReopened
        case .dismiss: .commitmentDismissed
        }
    }

    static func timelineChange(
        for event: CommitmentEvent
    ) -> MeetingMemoryTimelineCommitmentChange? {
        switch event.kind {
        case .confirm:
            nil
        case .reassign:
            event.assignee.map(MeetingMemoryTimelineCommitmentChange.reassigned)
        case .reschedule:
            .rescheduled(event.dueAt)
        case .complete:
            .completed
        case .reopen:
            .reopened
        case .dismiss:
            .dismissed
        }
    }

    static func timelineCommitmentKeys(
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
                    SELECT commitmentID FROM (
                        SELECT commitmentID
                        FROM meetingMemoryGraphMeetingCommitment
                        WHERE meetingID = ?
                        UNION
                        SELECT commitmentID
                        FROM commitmentEvent
                        WHERE sourceMeetingID = ?
                    )
                    ORDER BY commitmentID
                    LIMIT ?
                    """,
                arguments: [throughKey, throughKey, candidateLimit + 1])
        case .person(let personID):
            return try String.fetchAll(
                database,
                sql: """
                    SELECT candidate.commitmentID
                    FROM (
                        SELECT commitmentID
                        FROM meetingMemoryGraphMeetingCommitment
                        WHERE meetingID = ?
                        UNION
                        SELECT commitmentID
                        FROM commitmentEvent
                        WHERE sourceMeetingID = ?
                    ) AS candidate
                    JOIN meetingMemoryGraphCommitmentPerson AS ownerEdge
                      ON ownerEdge.commitmentID = candidate.commitmentID
                    WHERE ownerEdge.personID = ?
                    ORDER BY candidate.commitmentID
                    LIMIT ?
                    """,
                arguments: [
                    throughKey,
                    throughKey,
                    personID.rawValue.uuidString,
                    candidateLimit + 1
                ])
        }
    }

    static func appendCommitmentConfirmationTimelineItem(
        event: CommitmentEvent,
        continuity: CommitmentContinuityEnvelope,
        through: MeetingMemoryTimelineMeeting,
        accumulator: inout TimelineAccumulator,
        in database: Database
    ) throws {
        switch try timelineEvidence(
            for: continuity.sources,
            meetingID: through.id,
            in: database
        ) {
        case .current(let evidence):
            accumulator.items.append(MeetingMemoryTimelineItem(
                id: event.id.rawValue,
                kind: .commitmentConfirmed,
                entity: .commitment(continuity.commitment.id),
                text: continuity.commitment.title,
                origin: .confirmed,
                occurredAt: event.occurredAt,
                evidence: evidence))
        case .stale:
            accumulator.omit(.stale)
        case .unavailable:
            accumulator.omit(.unavailable)
        }
    }
    static func timelineEvidence(
        for source: DecisionSource,
        in database: Database
    ) throws -> TimelineEvidenceStatus {
        switch source.availability {
        case .stale: return .stale
        case .unavailable: return .unavailable
        case .current:
            return try timelineEvidence(
                meetingID: source.meetingID,
                transcriptRevision: source.sourceTranscriptRevision,
                segmentIDs: source.evidence.map(\.segmentID),
                in: database)
        }
    }

    static func timelineEvidence(
        for source: CommitmentSource,
        in database: Database
    ) throws -> TimelineEvidenceStatus {
        guard let meetingID = source.meetingID,
              let revision = source.transcriptRevision,
              !source.evidence.isEmpty,
              source.evidence.allSatisfy({ $0.segmentID != nil })
        else { return .unavailable }
        return try timelineEvidence(
            meetingID: meetingID,
            transcriptRevision: revision,
            segmentIDs: source.evidence.compactMap(\.segmentID),
            in: database)
    }

    static func timelineEvidence(
        for source: CommitmentEventEvidence,
        in database: Database
    ) throws -> TimelineEvidenceStatus {
        try timelineEvidence(
            meetingID: source.meetingID,
            transcriptRevision: source.sourceTranscriptRevision,
            segmentIDs: source.segmentIDs,
            in: database)
    }

    static func timelineEvidence(
        for sources: [DecisionSource],
        meetingID: MeetingID,
        in database: Database
    ) throws -> TimelineEvidenceStatus {
        let statuses = try sources
            .filter { $0.meetingID == meetingID }
            .map { try timelineEvidence(for: $0, in: database) }
        return bestTimelineEvidence(statuses)
    }

    static func timelineEvidence(
        for sources: [CommitmentSource],
        meetingID: MeetingID,
        in database: Database
    ) throws -> TimelineEvidenceStatus {
        let statuses = try sources
            .filter { $0.meetingID == meetingID }
            .map { try timelineEvidence(for: $0, in: database) }
        return bestTimelineEvidence(statuses)
    }

    static func bestTimelineEvidence<S: Sequence>(
        _ statuses: S
    ) -> TimelineEvidenceStatus where S.Element == TimelineEvidenceStatus {
        var sawStale = false
        var sawUnavailable = false
        for status in statuses {
            switch status {
            case .current:
                return status
            case .stale:
                sawStale = true
            case .unavailable:
                sawUnavailable = true
            }
        }
        if sawUnavailable { return .unavailable }
        if sawStale { return .stale }
        return .unavailable
    }

    static func timelineEvidence(
        meetingID: MeetingID,
        transcriptRevision: Int,
        segmentIDs: [UUID],
        in database: Database
    ) throws -> TimelineEvidenceStatus {
        let meetingKey = meetingID.rawValue.uuidString
        guard !segmentIDs.isEmpty,
              Set(segmentIDs).count == segmentIDs.count,
              let meeting = try MeetingRecord.fetchOne(database, key: meetingKey),
              meeting.deletedAt == nil
        else { return .unavailable }
        let segmentKeys = segmentIDs.map(\.uuidString)
        let records = try SegmentRecord.fetchAll(
            database,
            sql: """
                SELECT *
                FROM segment
                WHERE id IN (\(timelinePlaceholders(segmentKeys.count)))
                  AND meetingID = ?
                  AND deletedAt IS NULL
                  AND isFinal = 1
                  AND \(acceptedSegmentHasNoActiveCorrectionSQL)
                """,
            arguments: StatementArguments(segmentKeys + [meetingKey]))
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        guard recordsByID.count == segmentKeys.count else { return .unavailable }
        guard meeting.transcriptRevision == transcriptRevision else { return .stale }
        let evidence = try segmentKeys.map { segmentKey -> MeetingMemoryTimelineEvidence in
            guard let record = recordsByID[segmentKey] else {
                throw StorageError.invalidDerivedMaintenanceJob(
                    "memory timeline evidence changed during one SQLite snapshot")
            }
            let segment = try record.segment
            return MeetingMemoryTimelineEvidence(
                meetingID: meetingID,
                meetingTitle: meeting.title,
                meetingStartedAt: meeting.startedAt,
                transcriptRevision: transcriptRevision,
                segmentID: segment.id,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text,
                language: segment.language)
        }
        return .current(evidence)
    }

    static func combinedEvidenceStatus(
        _ lhs: TimelineEvidenceStatus,
        _ rhs: TimelineEvidenceStatus
    ) -> TimelineEvidenceStatus {
        switch (lhs, rhs) {
        case (.unavailable, _), (_, .unavailable): .unavailable
        case (.stale, _), (_, .stale): .stale
        case (.current(let left), .current(let right)): .current(left + right)
        }
    }

    static func timelineItemPrecedes(
        _ lhs: MeetingMemoryTimelineItem,
        _ rhs: MeetingMemoryTimelineItem
    ) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func timelinePlaceholders(_ count: Int) -> String {
        guard count > 0 else { return "NULL" }
        return Array(repeating: "?", count: count).joined(separator: ",")
    }

    static func requiredTimelineUUID(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw StorageError.invalidDerivedMaintenanceJob(
                "memory timeline contains a malformed identity")
        }
        return uuid
    }
}
