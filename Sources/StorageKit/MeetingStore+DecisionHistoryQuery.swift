import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// The current confirmed decisions about one exact topic family — "what
    /// did we decide about X". Superseded and reversed decisions are excluded
    /// by status, decisions about other subjects are excluded by the
    /// decision-topic authority, and generated observations that were never
    /// confirmed do not exist here at all.
    public func decisionHistory(
        _ query: DecisionHistoryQuery
    ) async throws -> MeetingMemoryGraphQueryResult {
        try await database.read { database in
            try Self.loadDecisionHistory(query, in: database)
        }
    }

    static func loadDecisionHistory(
        _ query: DecisionHistoryQuery,
        in database: Database
    ) throws -> MeetingMemoryGraphQueryResult {
        guard query.isValid else { return .abstained(.invalidQuery) }
        guard try meetingMemoryGraphProjectionIsReady(in: database) else {
            return .abstained(.projectionNotReady)
        }
        if let status = query.filter.status, status != .confirmed {
            return .abstained(.noMatchingFacts)
        }
        let topics = try liveTopicRecords(in: database)
        let queryKey = query.topicID.rawValue.uuidString
        guard topics[queryKey] != nil else {
            return .abstained(.topicUnavailable)
        }
        let root = try topicRoot(queryKey, among: topics)
        let familyIDs = try topics.values.compactMap { record -> String? in
            try topicRoot(record.id, among: topics).id == root.id
                ? record.id
                : nil
        }

        // Only links whose decision is still the current confirmed truth. A
        // superseded decision keeps its link — decisionConflicts serves it —
        // but it is no longer the answer to "what did we decide".
        let links = try DecisionTopicLinkRecord
            .filter(familyIDs.contains(Column("topicID")))
            .filter(Column("status") == DecisionTopicLinkStatus.confirmed.rawValue)
            .filter(Column("deletedAt") == nil)
            .order(Column("createdAt"), Column("id"))
            .fetchAll(database)
        guard !links.isEmpty else {
            return .abstained(.insufficientConfirmedDecision)
        }
        for link in links {
            guard try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS (
                        SELECT 1
                        FROM meetingMemoryGraphDecisionTopic
                        WHERE decisionID = ? AND topicID = ?
                    )
                    """,
                arguments: [link.decisionID, root.id]) ?? false
            else { return .abstained(.projectionInconsistent) }
        }

        var facts: [MeetingMemoryGraphFact] = []
        var matching = 0
        var omittedStale = 0
        var omittedUnavailable = 0
        let topic = try root.topic
        for link in links {
            let continuity = try loadDecisionContinuity(
                DecisionID(rawValue: try decisionHistoryUUID(link.decisionID)),
                in: database)
            guard continuity.decision.status == .confirmed else { continue }
            guard query.filter.includes(
                occurredAt: continuity.decision.createdAt,
                status: .confirmed)
            else { continue }
            matching += 1
            guard facts.count < query.itemLimit else { continue }
            guard let source = continuity.sources.first else {
                omittedUnavailable += 1
                continue
            }
            switch try timelineEvidence(for: source, in: database) {
            case .stale:
                omittedStale += 1
            case .unavailable:
                omittedUnavailable += 1
            case .current(let evidence):
                guard let primary = source.evidence.first?.segmentID else {
                    omittedUnavailable += 1
                    continue
                }
                facts.append(MeetingMemoryGraphFact(
                    id: .decisionAboutness(DecisionTopicLinkID(
                        rawValue: try decisionHistoryUUID(link.id))),
                    kind: .decisionAboutTopic,
                    subject: .decision(continuity.decision.id),
                    object: .topic(topic.id),
                    subjectText: continuity.decision.statement,
                    objectText: topic.preferredLabel,
                    status: .confirmed,
                    occurredAt: continuity.decision.createdAt,
                    evidence: evidence,
                    primaryEvidenceSegmentID: primary))
            }
        }
        if facts.isEmpty {
            if omittedStale > 0 { return .abstained(.staleEvidenceOnly) }
            if omittedUnavailable > 0 { return .abstained(.evidenceUnavailable) }
            return .abstained(.insufficientConfirmedDecision)
        }
        let generation = try meetingMemoryGraphProjectionGeneration(in: database)
        return .facts(MeetingMemoryGraphFactPage(
            facts: facts,
            hasMore: matching > query.itemLimit,
            projectionGeneration: generation,
            omittedStaleCount: omittedStale,
            omittedUnavailableCount: omittedUnavailable))
    }

    private static func decisionHistoryUUID(_ raw: String) throws -> UUID {
        guard let value = UUID(uuidString: raw) else {
            throw StorageError.invalidDecisionContinuity(
                "decision history identity is malformed")
        }
        return value
    }
}
