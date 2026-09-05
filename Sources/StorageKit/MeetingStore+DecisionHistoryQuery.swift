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
        let familyIDs = try decisionHistoryFamilyIDs(
            rootID: root.id,
            among: topics)

        // Only links whose decision is still the current confirmed truth. A
        // superseded decision keeps its link — decisionConflicts serves it —
        // but it is no longer the answer to "what did we decide".
        let links = try decisionHistoryLinks(
            for: familyIDs,
            in: database)
        guard !links.isEmpty else {
            return .abstained(.insufficientConfirmedDecision)
        }
        guard try decisionHistoryProjectionIsConsistent(
            links: links,
            rootTopicID: root.id,
            in: database)
        else {
            return .abstained(.projectionInconsistent)
        }

        return try decisionHistoryPage(
            query: query,
            topic: root.topic,
            links: links,
            in: database)
    }

    private static func decisionHistoryFamilyIDs(
        rootID: String,
        among topics: [String: TopicRecord]
    ) throws -> [String] {
        try topics.values.compactMap { record -> String? in
            try topicRoot(record.id, among: topics).id == rootID
                ? record.id
                : nil
        }
    }

    private static func decisionHistoryLinks(
        for familyIDs: [String],
        in database: Database
    ) throws -> [DecisionTopicLinkRecord] {
        try DecisionTopicLinkRecord
            .filter(familyIDs.contains(Column("topicID")))
            .filter(Column("status") == DecisionTopicLinkStatus.confirmed.rawValue)
            .filter(Column("deletedAt") == nil)
            .order(Column("createdAt"), Column("id"))
            .fetchAll(database)
    }

    private static func decisionHistoryProjectionIsConsistent(
        links: [DecisionTopicLinkRecord],
        rootTopicID: String,
        in database: Database
    ) throws -> Bool {
        for link in links {
            let exists = try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS (
                        SELECT 1
                        FROM meetingMemoryGraphDecisionTopic
                        WHERE decisionID = ? AND topicID = ?
                    )
                    """,
                arguments: [link.decisionID, rootTopicID]) ?? false
            guard exists else { return false }
        }
        return true
    }

    private static func decisionHistoryPage(
        query: DecisionHistoryQuery,
        topic: Topic,
        links: [DecisionTopicLinkRecord],
        in database: Database
    ) throws -> MeetingMemoryGraphQueryResult {
        var page = DecisionHistoryPage(itemLimit: query.itemLimit)
        for link in links {
            guard let continuity = try matchingDecisionHistory(
                link: link,
                filter: query.filter,
                in: database)
            else { continue }
            page.recordMatch()
            guard page.needsHydration else { continue }
            page.record(try decisionHistoryFact(
                link: link,
                continuity: continuity,
                topic: topic,
                in: database))
        }
        guard !page.facts.isEmpty else {
            return .abstained(page.emptyReason)
        }
        let generation = try meetingMemoryGraphProjectionGeneration(in: database)
        return .facts(page.factPage(projectionGeneration: generation))
    }

    private static func matchingDecisionHistory(
        link: DecisionTopicLinkRecord,
        filter: MeetingMemoryGraphFactFilter,
        in database: Database
    ) throws -> DecisionContinuity? {
        let continuity = try loadDecisionContinuity(
            DecisionID(rawValue: try decisionHistoryUUID(link.decisionID)),
            in: database)
        guard continuity.decision.status == .confirmed,
              filter.includes(
                occurredAt: continuity.decision.createdAt,
                status: .confirmed)
        else { return nil }
        return continuity
    }

    private static func decisionHistoryFact(
        link: DecisionTopicLinkRecord,
        continuity: DecisionContinuity,
        topic: Topic,
        in database: Database
    ) throws -> DecisionHistoryHydration {
        guard let source = continuity.sources.first else {
            return .unavailable
        }
        switch try timelineEvidence(for: source, in: database) {
        case .stale:
            return .stale
        case .unavailable:
            return .unavailable
        case .current(let evidence):
            guard let primary = source.evidence.first?.segmentID else {
                return .unavailable
            }
            return .fact(MeetingMemoryGraphFact(
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

    private static func decisionHistoryUUID(_ raw: String) throws -> UUID {
        guard let value = UUID(uuidString: raw) else {
            throw StorageError.invalidDecisionContinuity(
                "decision history identity is malformed")
        }
        return value
    }
}

private enum DecisionHistoryHydration {
    case fact(MeetingMemoryGraphFact)
    case stale
    case unavailable
}

private struct DecisionHistoryPage {
    let itemLimit: Int
    private(set) var facts: [MeetingMemoryGraphFact] = []
    private var matchingCount = 0
    private var omittedStaleCount = 0
    private var omittedUnavailableCount = 0

    init(itemLimit: Int) {
        self.itemLimit = itemLimit
    }

    var needsHydration: Bool {
        facts.count < itemLimit
    }

    var emptyReason: MeetingMemoryGraphQueryAbstention {
        if omittedStaleCount > 0 { return .staleEvidenceOnly }
        if omittedUnavailableCount > 0 { return .evidenceUnavailable }
        return .insufficientConfirmedDecision
    }

    mutating func recordMatch() {
        matchingCount += 1
    }

    mutating func record(_ hydration: DecisionHistoryHydration) {
        switch hydration {
        case .fact(let fact):
            facts.append(fact)
        case .stale:
            omittedStaleCount += 1
        case .unavailable:
            omittedUnavailableCount += 1
        }
    }

    func factPage(projectionGeneration: Int) -> MeetingMemoryGraphFactPage {
        MeetingMemoryGraphFactPage(
            facts: facts,
            hasMore: matchingCount > itemLimit,
            projectionGeneration: projectionGeneration,
            omittedStaleCount: omittedStaleCount,
            omittedUnavailableCount: omittedUnavailableCount)
    }
}
