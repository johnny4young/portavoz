import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Confirmed decision replacements about one exact topic family. The graph
    /// edge only nominates candidates; every returned relationship is
    /// re-derived from decision continuity and the decision-topic authority,
    /// and a generated guess can never appear because it was never confirmed.
    public func decisionConflicts(
        _ query: DecisionConflictsQuery
    ) async throws -> MeetingMemoryGraphQueryResult {
        try await database.read { database in
            try Self.loadDecisionConflicts(query, in: database)
        }
    }

    /// Confirmed decision replacements about one exact topic family whose
    /// relationship event occurred after one exact anchor meeting ended.
    public func changeSince(
        _ query: ChangeSinceQuery
    ) async throws -> MeetingMemoryGraphQueryResult {
        try await database.read { database in
            try Self.loadChangeSince(query, in: database)
        }
    }

    static func loadDecisionConflicts(
        _ query: DecisionConflictsQuery,
        in database: Database
    ) throws -> MeetingMemoryGraphQueryResult {
        try loadDecisionRelationships(
            topicID: query.topicID,
            itemLimit: query.itemLimit,
            filter: query.filter,
            isValid: query.isValid,
            occurredAfter: nil,
            in: database)
    }

    static func loadChangeSince(
        _ query: ChangeSinceQuery,
        in database: Database
    ) throws -> MeetingMemoryGraphQueryResult {
        guard query.isValid else { return .abstained(.invalidQuery) }
        // The anchor resolves before any topology is consulted: an unknown or
        // deleted baseline meeting means "since when" has no exact answer.
        guard let anchor = try MeetingRecord.fetchOne(
            database,
            key: query.sinceMeetingID.rawValue.uuidString),
            anchor.deletedAt == nil
        else {
            return .abstained(.missingTemporalBaseline)
        }
        return try loadDecisionRelationships(
            topicID: query.topicID,
            itemLimit: query.itemLimit,
            filter: query.filter,
            isValid: true,
            occurredAfter: anchor.endedAt ?? anchor.startedAt,
            in: database)
    }

    private static func loadDecisionRelationships(
        topicID: TopicID,
        itemLimit: Int,
        filter: MeetingMemoryGraphFactFilter,
        isValid: Bool,
        occurredAfter anchor: Date?,
        in database: Database
    ) throws -> MeetingMemoryGraphQueryResult {
        guard isValid else { return .abstained(.invalidQuery) }
        guard try meetingMemoryGraphProjectionIsReady(in: database) else {
            return .abstained(.projectionNotReady)
        }
        // Relationships are explicitly confirmed truth; there is no "active"
        // reading of a supersession.
        if let status = filter.status, status != .confirmed {
            return .abstained(.noMatchingFacts)
        }
        let topics = try liveTopicRecords(in: database)
        let queryKey = topicID.rawValue.uuidString
        guard topics[queryKey] != nil else {
            return .abstained(.topicUnavailable)
        }
        let root = try topicRoot(queryKey, among: topics)
        let familyIDs = try decisionRelationshipFamilyIDs(
            rootID: root.id,
            among: topics)

        let linkedDecisionIDs = try decisionRelationshipLinkedDecisionIDs(
            familyIDs: familyIDs,
            in: database)
        guard !linkedDecisionIDs.isEmpty else {
            return .abstained(.noMatchingFacts)
        }
        guard try decisionRelationshipProjectionIsConsistent(
            decisionIDs: linkedDecisionIDs,
            rootTopicID: root.id,
            in: database)
        else {
            return .abstained(.projectionInconsistent)
        }

        let events = try decisionRelationshipEvents(
            linkedDecisionIDs: linkedDecisionIDs,
            in: database)
        let matching = decisionRelationshipEvents(
            events,
            occurredAfter: anchor,
            filter: filter)
        if matching.isEmpty {
            return .abstained(anchor == nil ? .unsupportedConflict : .noMatchingFacts)
        }
        return try decisionRelationshipPage(
            events: matching,
            itemLimit: itemLimit,
            emptyReason: anchor == nil ? .unsupportedConflict : .noMatchingFacts,
            in: database)
    }

    private static func decisionRelationshipFamilyIDs(
        rootID: String,
        among topics: [String: TopicRecord]
    ) throws -> [String] {
        try topics.values.compactMap { record -> String? in
            try topicRoot(record.id, among: topics).id == rootID
                ? record.id
                : nil
        }
    }

    private static func decisionRelationshipLinkedDecisionIDs(
        familyIDs: [String],
        in database: Database
    ) throws -> Set<String> {
        try Set(String.fetchAll(
            database,
            sql: """
                SELECT DISTINCT link.decisionID
                FROM decisionTopicLink AS link
                JOIN decisionContinuity AS decision ON decision.id = link.decisionID
                WHERE link.topicID IN (\(placeholders(familyIDs.count)))
                  AND link.status = 'confirmed'
                  AND link.deletedAt IS NULL
                  AND decision.deletedAt IS NULL
                """,
            arguments: StatementArguments(familyIDs)))
    }

    private static func decisionRelationshipProjectionIsConsistent(
        decisionIDs: Set<String>,
        rootTopicID: String,
        in database: Database
    ) throws -> Bool {
        // The graph may only confirm topology the authority already asserts;
        // a linked decision missing its projection edge is an inconsistency,
        // not something to silently repair here.
        for decisionID in decisionIDs.sorted() {
            guard try graphContainsDecisionTopicEdge(
                decisionID: decisionID,
                topicID: rootTopicID,
                in: database)
            else { return false }
        }
        return true
    }

    private static func decisionRelationshipEvents(
        linkedDecisionIDs: Set<String>,
        in database: Database
    ) throws -> [DecisionEvent] {
        // Either side of the relationship being about the topic makes the
        // replacement relevant to it.
        let candidates = Array(linkedDecisionIDs)
        return try DecisionContinuityEventRecord
            .filter(["supersede", "reverse"].contains(Column("kind")))
            .filter(
                candidates.contains(Column("decisionID"))
                    || candidates.contains(Column("relatedDecisionID")))
            .order(Column("occurredAt"), Column("id"))
            .fetchAll(database)
            .map { try $0.event }
    }

    private static func decisionRelationshipEvents(
        _ events: [DecisionEvent],
        occurredAfter anchor: Date?,
        filter: MeetingMemoryGraphFactFilter
    ) -> [DecisionEvent] {
        events.filter { event in
            guard let anchor else { return true }
            return event.occurredAt > anchor
        }.filter { event in
            filter.includes(occurredAt: event.occurredAt, status: .confirmed)
        }
    }

    private static func decisionRelationshipPage(
        events: [DecisionEvent],
        itemLimit: Int,
        emptyReason: MeetingMemoryGraphQueryAbstention,
        in database: Database
    ) throws -> MeetingMemoryGraphQueryResult {
        var page = DecisionRelationshipPage(
            itemLimit: itemLimit,
            matchingCount: events.count)
        for event in events {
            guard page.needsHydration else { break }
            page.record(try decisionRelationshipFact(event, in: database))
        }
        guard !page.facts.isEmpty else {
            return .abstained(page.emptyReason(default: emptyReason))
        }
        let generation = try meetingMemoryGraphProjectionGeneration(in: database)
        return .facts(page.factPage(projectionGeneration: generation))
    }

    fileprivate enum DecisionRelationshipHydration {
        case fact(MeetingMemoryGraphFact)
        case stale
        case unavailable
    }

    /// Rehydrates one relationship entirely from decision continuity: both
    /// statements and both confirm-source evidence sets, all current. The
    /// evidence orders the replaced decision first, then its successor, so the
    /// reader sees what was decided before what replaced it.
    private static func decisionRelationshipFact(
        _ event: DecisionEvent,
        in database: Database
    ) throws -> DecisionRelationshipHydration {
        guard let successorID = event.relatedDecisionID else {
            return .unavailable
        }
        let replaced = try loadDecisionContinuity(event.decisionID, in: database)
        let successor = try loadDecisionContinuity(successorID, in: database)
        guard let replacedSource = replaced.sources.first,
              let successorSource = successor.sources.first
        else { return .unavailable }

        var evidence: [MeetingMemoryGraphEvidence] = []
        for source in [replacedSource, successorSource] {
            switch try timelineEvidence(for: source, in: database) {
            case .stale:
                return .stale
            case .unavailable:
                return .unavailable
            case .current(let current):
                evidence.append(contentsOf: current)
            }
        }
        guard let primary = successorSource.evidence.first?.segmentID else {
            return .unavailable
        }
        return .fact(MeetingMemoryGraphFact(
            id: .decisionRelationship(event.id),
            kind: .decisionSupersededDecision,
            subject: .decision(successorID),
            object: .decision(event.decisionID),
            subjectText: successor.decision.statement,
            objectText: replaced.decision.statement,
            status: .confirmed,
            occurredAt: event.occurredAt,
            evidence: evidence,
            primaryEvidenceSegmentID: primary))
    }

    private static func graphContainsDecisionTopicEdge(
        decisionID: String,
        topicID: String,
        in database: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS (
                    SELECT 1
                    FROM meetingMemoryGraphDecisionTopic
                    WHERE decisionID = ? AND topicID = ?
                )
                """,
            arguments: [decisionID, topicID]) ?? false
    }
}

private struct DecisionRelationshipPage {
    let itemLimit: Int
    let matchingCount: Int
    private(set) var facts: [MeetingMemoryGraphFact] = []
    private var omittedStaleCount = 0
    private var omittedUnavailableCount = 0

    init(itemLimit: Int, matchingCount: Int) {
        self.itemLimit = itemLimit
        self.matchingCount = matchingCount
    }

    var needsHydration: Bool {
        facts.count < itemLimit
    }

    mutating func record(_ hydration: MeetingStore.DecisionRelationshipHydration) {
        switch hydration {
        case .fact(let fact):
            facts.append(fact)
        case .stale:
            omittedStaleCount += 1
        case .unavailable:
            omittedUnavailableCount += 1
        }
    }

    func emptyReason(
        default fallback: MeetingMemoryGraphQueryAbstention
    ) -> MeetingMemoryGraphQueryAbstention {
        if omittedStaleCount > 0 { return .staleEvidenceOnly }
        if omittedUnavailableCount > 0 { return .evidenceUnavailable }
        return fallback
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
