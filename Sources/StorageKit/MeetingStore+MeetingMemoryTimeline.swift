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

        let resolvedSubject: MeetingMemoryTimelineSubject
        let subjectKey: String
        switch query.subject {
        case .person(let personID):
            guard let person = try PersonRecord.fetchOne(
                database,
                key: personID.rawValue.uuidString),
                  person.deletedAt == nil
            else { return .abstained(.subjectUnavailable) }
            resolvedSubject = .person(personID)
            subjectKey = person.id
        case .topic(let topicID):
            let topics = try liveTopicRecords(in: database)
            guard topics[topicID.rawValue.uuidString] != nil else {
                return .abstained(.subjectUnavailable)
            }
            let root = try topicRoot(topicID.rawValue.uuidString, among: topics)
            let rootID = TopicID(rawValue: try requiredTimelineUUID(root.id))
            resolvedSubject = .topic(rootID)
            subjectKey = root.id
        }

        let relatedMeetings = try timelineMeetings(
            for: resolvedSubject,
            subjectKey: subjectKey,
            in: database)
        guard !relatedMeetings.isEmpty else {
            return .abstained(.subjectUnavailable)
        }

        let throughIndex: Int
        if let requestedMeetingID = query.throughMeetingID {
            guard let index = relatedMeetings.firstIndex(where: {
                $0.id == requestedMeetingID
            }) else { return .abstained(.anchorNotRelated) }
            throughIndex = index
        } else {
            throughIndex = relatedMeetings.index(before: relatedMeetings.endIndex)
        }
        guard throughIndex > relatedMeetings.startIndex else {
            return .abstained(.missingTemporalBaseline)
        }

        let baseline = relatedMeetings[relatedMeetings.index(before: throughIndex)]
        let through = relatedMeetings[throughIndex]
        let candidateLimit = min(
            MeetingMemoryTimelineQuery.maximumItemLimit * 8,
            max(32, query.itemLimit * 4))
        var accumulator = TimelineAccumulator()

        if case .topic = resolvedSubject {
            try appendDecisionTimelineItems(
                baseline: baseline,
                through: through,
                candidateLimit: candidateLimit,
                accumulator: &accumulator,
                in: database)
        }
        try appendCommitmentTimelineItems(
            subject: resolvedSubject,
            through: through,
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
        return .timeline(MeetingMemoryTimelinePage(
            subject: resolvedSubject,
            baseline: baseline,
            through: through,
            items: items,
            hasMore: hasMore,
            projectionGeneration: generation,
            omittedStaleCount: accumulator.staleCount,
            omittedUnavailableCount: accumulator.unavailableCount,
            unsupportedKinds: [
                .commitmentReassigned,
                .commitmentRescheduled,
                .commitmentCompleted,
                .commitmentReopened,
                .commitmentDismissed,
                .unresolvedQuestion,
            ]))
    }
}

private extension MeetingStore {
    struct TimelineAccumulator {
        var items: [MeetingMemoryTimelineItem] = []
        var candidateOverflow = false
        var staleCount = 0
        var unavailableCount = 0

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
                candidateLimit + 1,
            ])
        if fetchedDecisionKeys.count > candidateLimit {
            accumulator.candidateOverflow = true
        }
        let decisionKeys = fetchedDecisionKeys.prefix(candidateLimit)
        for decisionKey in decisionKeys {
            let decisionID = DecisionID(rawValue: try requiredTimelineUUID(decisionKey))
            let continuity = try loadDecisionContinuity(decisionID, in: database)
            for event in continuity.events {
                switch event.kind {
                case .confirm:
                    guard let sourceID = event.sourceID,
                          let source = continuity.sources.first(where: {
                              $0.id == sourceID && $0.meetingID == through.id
                          })
                    else { continue }
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
                case .supersede, .reverse:
                    guard let successorID = event.relatedDecisionID else { continue }
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
                        accumulator.omit(combinedEvidenceStatus(
                            priorEvidence,
                            successorEvidence))
                        continue
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
            }
        }
    }

    static func appendCommitmentTimelineItems(
        subject: MeetingMemoryTimelineSubject,
        through: MeetingMemoryTimelineMeeting,
        candidateLimit: Int,
        accumulator: inout TimelineAccumulator,
        in database: Database
    ) throws {
        let throughKey = through.id.rawValue.uuidString
        let fetchedCommitmentKeys: [String]
        switch subject {
        case .topic:
            fetchedCommitmentKeys = try String.fetchAll(
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
            fetchedCommitmentKeys = try String.fetchAll(
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
                    candidateLimit + 1,
                ])
        }
        if fetchedCommitmentKeys.count > candidateLimit {
            accumulator.candidateOverflow = true
        }
        let commitmentKeys = fetchedCommitmentKeys.prefix(candidateLimit)
        for commitmentKey in commitmentKeys {
            let commitmentID = CommitmentID(
                rawValue: try requiredTimelineUUID(commitmentKey))
            let continuity = try loadCommitmentContinuity(commitmentID, in: database)
            for event in continuity.events where event.kind == .confirm
                && event.sourceMeetingID == through.id {
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
