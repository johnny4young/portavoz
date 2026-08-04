import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Reads explicit active blocker facts for one exact commitment. Graph rows
    /// narrow the topology only; authoritative continuity and current accepted
    /// transcript evidence are rehydrated in the same SQLite snapshot.
    public func commitmentBlockerFacts(
        _ query: CommitmentBlockerQuery
    ) async throws -> MeetingMemoryGraphQueryResult {
        guard query.isValid else { return .abstained(.invalidQuery) }
        return try await database.read { database in
            try Self.loadCommitmentBlockerFacts(query, in: database)
        }
    }

    static func loadCommitmentBlockerFacts(
        _ query: CommitmentBlockerQuery,
        in database: Database
    ) throws -> MeetingMemoryGraphQueryResult {
        guard query.isValid else { return .abstained(.invalidQuery) }
        guard try meetingMemoryGraphProjectionIsReady(in: database) else {
            return .abstained(.projectionNotReady)
        }
        if let status = query.filter.status, status != .active {
            return .abstained(.noMatchingFacts)
        }
        guard try graphQueryCommitmentIsAvailable(query.commitmentID, in: database) else {
            return .abstained(.commitmentUnavailable)
        }
        let candidates = try blockerFactCandidates(query, in: database)
        guard !candidates.keys.isEmpty else {
            return .abstained(query.filter.isUnrestricted
                ? .unsupportedCausalLink
                : .noMatchingFacts)
        }

        let hydration = try hydrateBlockerFacts(
            candidates.keys,
            query: query,
            in: database)
        if hydration.facts.isEmpty {
            if candidates.exceededBudget {
                return .abstained(.candidateBudgetExceeded)
            }
            if hydration.unavailableCount > 0 {
                return .abstained(.evidenceUnavailable)
            }
            if hydration.staleCount > 0 {
                return .abstained(.staleEvidenceOnly)
            }
            return .abstained(.unsupportedCausalLink)
        }
        let generation = try Int.fetchOne(
            database,
            sql: """
                SELECT sourceGeneration
                FROM meetingMemoryGraphProjectionState
                WHERE id = 'current'
                """) ?? 0
        return .facts(MeetingMemoryGraphFactPage(
            facts: Array(hydration.facts.prefix(query.itemLimit)),
            hasMore: candidates.exceededBudget
                || hydration.facts.count > query.itemLimit,
            projectionGeneration: generation,
            omittedStaleCount: hydration.staleCount,
            omittedUnavailableCount: hydration.unavailableCount))
    }

    private static func graphQueryCommitmentIsAvailable(
        _ commitmentID: CommitmentID,
        in database: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS (
                    SELECT 1
                    FROM commitment
                    WHERE id = ?
                      AND status = 'confirmed'
                      AND deletedAt IS NULL
                )
                """,
            arguments: [commitmentID.rawValue.uuidString]) ?? false
    }

    private static func blockerFactCandidates(
        _ query: CommitmentBlockerQuery,
        in database: Database
    ) throws -> BlockerFactCandidates {
        let limit = min(
            MeetingMemoryGraphQueryBudget.maximumCandidateCount,
            max(
                MeetingMemoryGraphQueryBudget.minimumCandidateCount,
                query.itemLimit * MeetingMemoryGraphQueryBudget.candidateMultiplier))
        var sql = """
                SELECT edge.blockerID
                FROM meetingMemoryGraphDecisionCommitmentBlocker AS edge
                JOIN decisionCommitmentBlocker AS blocker
                  ON blocker.id = edge.blockerID
                 AND blocker.decisionID = edge.decisionID
                 AND blocker.commitmentID = edge.commitmentID
                JOIN decisionContinuity AS decision
                  ON decision.id = edge.decisionID
                WHERE edge.commitmentID = ?
                  AND blocker.status = 'active'
                  AND blocker.deletedAt IS NULL
                  AND decision.status = 'confirmed'
                  AND decision.deletedAt IS NULL
            """
        var arguments: StatementArguments = [
            query.commitmentID.rawValue.uuidString
        ]
        if let lower = query.filter.occurredAtOrAfter {
            sql += "\n  AND blocker.confirmedAt >= ?"
            arguments += [lower]
        }
        if let upper = query.filter.occurredBefore {
            sql += "\n  AND blocker.confirmedAt < ?"
            arguments += [upper]
        }
        sql += """

                ORDER BY blocker.confirmedAt DESC, blocker.id
                LIMIT ?
            """
        arguments += [limit + 1]
        let keys = try String.fetchAll(
            database,
            sql: sql,
            arguments: arguments)
        return BlockerFactCandidates(
            keys: Array(keys.prefix(limit)),
            exceededBudget: keys.count > limit)
    }

    private static func hydrateBlockerFacts<S: Sequence>(
        _ blockerKeys: S,
        query: CommitmentBlockerQuery,
        in database: Database
    ) throws -> BlockerFactHydration where S.Element == String {
        var hydration = BlockerFactHydration()
        for blockerKey in blockerKeys {
            let blockerID = DecisionCommitmentBlockerID(
                rawValue: try requiredTimelineUUID(blockerKey))
            let continuity = try loadDecisionCommitmentBlockerContinuity(
                blockerID,
                in: database)
            guard continuity.blocker.commitmentID == query.commitmentID,
                  continuity.blocker.status == .active
            else {
                throw StorageError.invalidDerivedMaintenanceJob(
                    "memory graph blocker topology disagrees with authority")
            }
            guard query.filter.includes(
                occurredAt: continuity.blocker.confirmedAt,
                status: .active)
            else {
                throw StorageError.invalidDerivedMaintenanceJob(
                    "memory graph blocker candidate violates exact filter")
            }
            let decision = try loadDecisionContinuity(
                continuity.blocker.decisionID,
                in: database)
            let commitment = try loadCommitmentContinuity(
                continuity.blocker.commitmentID,
                in: database)
            switch try commitmentBlockerFactEvidence(
                commitment: commitment,
                blocker: continuity.openingEvidence,
                in: database
            ) {
            case .current(let evidence):
                hydration.facts.append(MeetingMemoryGraphFact(
                    id: .blocker(continuity.blocker.id),
                    kind: .decisionBlocksCommitment,
                    subject: .decision(continuity.blocker.decisionID),
                    object: .commitment(continuity.blocker.commitmentID),
                    subjectText: decision.decision.statement,
                    objectText: commitment.commitment.title,
                    status: .active,
                    occurredAt: continuity.blocker.confirmedAt,
                    evidence: evidence,
                    primaryEvidenceSegmentID:
                        continuity.openingEvidence.segmentIDs[0]))
            case .stale:
                hydration.staleCount += 1
            case .unavailable:
                hydration.unavailableCount += 1
            }
        }
        return hydration
    }

    private static func commitmentBlockerFactEvidence(
        commitment: CommitmentContinuityEnvelope,
        blocker: DecisionCommitmentBlockerEvidence,
        in database: Database
    ) throws -> TimelineEvidenceStatus {
        guard !commitment.sources.isEmpty
        else { return .unavailable }
        let commitmentStatus = bestTimelineEvidence(try commitment.sources.map {
            try timelineEvidence(for: $0, in: database)
        })
        let statuses = [
            commitmentStatus,
            try timelineEvidence(for: blocker, in: database)
        ]
        var evidence: [MeetingMemoryTimelineEvidence] = []
        var seen: Set<GraphEvidenceKey> = []
        var sawStale = false
        var sawUnavailable = false
        for status in statuses {
            switch status {
            case .current(let current):
                for item in current where seen.insert(GraphEvidenceKey(item)).inserted {
                    evidence.append(item)
                }
            case .stale:
                sawStale = true
            case .unavailable:
                sawUnavailable = true
            }
        }
        if sawUnavailable { return .unavailable }
        if sawStale { return .stale }
        return evidence.isEmpty ? .unavailable : .current(evidence)
    }
}

private struct BlockerFactHydration {
    var facts: [MeetingMemoryGraphFact] = []
    var staleCount = 0
    var unavailableCount = 0
}

private struct BlockerFactCandidates {
    let keys: [String]
    let exceededBudget: Bool
}

private struct GraphEvidenceKey: Hashable {
    let meetingID: MeetingID
    let segmentID: UUID

    init(_ evidence: MeetingMemoryTimelineEvidence) {
        meetingID = evidence.meetingID
        segmentID = evidence.segmentID
    }
}

enum MeetingMemoryGraphQueryBudget {
    static let minimumCandidateCount = 32
    static let candidateMultiplier = 4
    static let maximumCandidateCount = 800
}
