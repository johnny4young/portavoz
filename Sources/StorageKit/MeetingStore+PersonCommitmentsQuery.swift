import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Returns current source-backed commitments for one exact canonical
    /// person. Graph edges narrow candidates; current ownership, lifecycle,
    /// wording, and evidence are always rehydrated from authority.
    public func personCommitmentFacts(
        _ query: PersonCommitmentsQuery
    ) async throws -> MeetingMemoryGraphQueryResult {
        guard query.isValid else { return .abstained(.invalidQuery) }
        return try await database.read { database in
            try Self.loadPersonCommitmentFacts(query, in: database)
        }
    }

    static func loadPersonCommitmentFacts(
        _ query: PersonCommitmentsQuery,
        in database: Database
    ) throws -> MeetingMemoryGraphQueryResult {
        guard query.isValid else { return .abstained(.invalidQuery) }
        guard try meetingMemoryGraphProjectionIsReady(in: database) else {
            return .abstained(.projectionNotReady)
        }
        if let status = query.filter.status, status != .active {
            return .abstained(.noMatchingFacts)
        }
        guard let person = try graphQueryPerson(
            query.personID,
            in: database)
        else { return .abstained(.personUnavailable) }

        let authoritativeCount = try activeCommitmentCount(
            ownedBy: query.personID,
            in: database)
        guard authoritativeCount > 0 else {
            return .abstained(.noActiveCommitments)
        }
        guard try projectedActiveCommitmentCount(
            ownedBy: query.personID,
            in: database) == authoritativeCount
        else { return .abstained(.projectionInconsistent) }
        let candidates = try personCommitmentCandidates(query, in: database)
        guard !candidates.keys.isEmpty else {
            return .abstained(query.filter.isUnrestricted
                ? .projectionInconsistent
                : .noMatchingFacts)
        }

        let hydration = try hydratePersonCommitmentFacts(
            candidates.keys,
            person: person,
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
            return .abstained(.projectionInconsistent)
        }

        let generation = try meetingMemoryGraphProjectionGeneration(in: database)
        return .facts(MeetingMemoryGraphFactPage(
            facts: Array(hydration.facts.prefix(query.itemLimit)),
            hasMore: candidates.exceededBudget
                || hydration.facts.count > query.itemLimit,
            projectionGeneration: generation,
            omittedStaleCount: hydration.staleCount,
            omittedUnavailableCount: hydration.unavailableCount))
    }

    private static func graphQueryPerson(
        _ personID: PersonID,
        in database: Database
    ) throws -> Person? {
        try PersonRecord.fetchOne(
            database,
            sql: "SELECT * FROM person WHERE id = ? AND deletedAt IS NULL",
            arguments: [personID.rawValue.uuidString])?.person
    }

    private static func activeCommitmentCount(
        ownedBy personID: PersonID,
        in database: Database
    ) throws -> Int {
        try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM commitment
                WHERE assigneeKind = 'person'
                  AND canonicalPersonID = ?
                  AND status = 'confirmed'
                  AND deletedAt IS NULL
                """,
            arguments: [personID.rawValue.uuidString]) ?? 0
    }

    private static func personCommitmentCandidates(
        _ query: PersonCommitmentsQuery,
        in database: Database
    ) throws -> PersonCommitmentCandidates {
        let limit = min(
            MeetingMemoryGraphQueryBudget.maximumCandidateCount,
            max(
                MeetingMemoryGraphQueryBudget.minimumCandidateCount,
                query.itemLimit * MeetingMemoryGraphQueryBudget.candidateMultiplier))
        var sql = """
                WITH latestReassignment AS (
                    SELECT commitmentID,
                           occurredAt,
                           ROW_NUMBER() OVER (
                               PARTITION BY commitmentID
                               ORDER BY occurredAt DESC, id DESC
                           ) AS rowRank
                    FROM commitmentEvent
                    WHERE kind = 'reassign'
                )
                SELECT edge.commitmentID
                FROM meetingMemoryGraphCommitmentPerson AS edge
                JOIN commitment
                  ON commitment.id = edge.commitmentID
                 AND commitment.canonicalPersonID = edge.personID
                LEFT JOIN latestReassignment
                  ON latestReassignment.commitmentID = commitment.id
                 AND latestReassignment.rowRank = 1
                WHERE edge.personID = ?
                  AND commitment.assigneeKind = 'person'
                  AND commitment.status = 'confirmed'
                  AND commitment.deletedAt IS NULL
            """
        var arguments: StatementArguments = [query.personID.rawValue.uuidString]
        let occurrence = "COALESCE(latestReassignment.occurredAt, commitment.createdAt)"
        if let lower = query.filter.occurredAtOrAfter {
            sql += "\n  AND \(occurrence) >= ?"
            arguments += [lower]
        }
        if let upper = query.filter.occurredBefore {
            sql += "\n  AND \(occurrence) < ?"
            arguments += [upper]
        }
        sql += """

                ORDER BY \(occurrence) DESC, commitment.id
                LIMIT ?
            """
        arguments += [limit + 1]
        let keys = try String.fetchAll(
            database,
            sql: sql,
            arguments: arguments)
        return PersonCommitmentCandidates(
            keys: Array(keys.prefix(limit)),
            exceededBudget: keys.count > limit)
    }

    private static func projectedActiveCommitmentCount(
        ownedBy personID: PersonID,
        in database: Database
    ) throws -> Int {
        try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM meetingMemoryGraphCommitmentPerson AS edge
                JOIN commitment
                  ON commitment.id = edge.commitmentID
                 AND commitment.canonicalPersonID = edge.personID
                WHERE edge.personID = ?
                  AND commitment.assigneeKind = 'person'
                  AND commitment.status = 'confirmed'
                  AND commitment.deletedAt IS NULL
                """,
            arguments: [personID.rawValue.uuidString]) ?? 0
    }

    private static func hydratePersonCommitmentFacts<S: Sequence>(
        _ commitmentKeys: S,
        person: Person,
        query: PersonCommitmentsQuery,
        in database: Database
    ) throws -> PersonCommitmentHydration where S.Element == String {
        var hydration = PersonCommitmentHydration()
        for key in commitmentKeys {
            let commitmentID = CommitmentID(
                rawValue: try requiredTimelineUUID(key))
            let continuity = try loadCommitmentContinuity(
                commitmentID,
                in: database)
            guard continuity.commitment.status == .confirmed,
                  continuity.commitment.assignee == .person(query.personID)
            else {
                throw StorageError.invalidDerivedMaintenanceJob(
                    "memory graph commitment ownership disagrees with authority")
            }
            switch try currentCommitmentAuthority(
                continuity,
                in: database) {
            case .current(let evidence, let occurredAt):
                guard query.filter.includes(
                    occurredAt: occurredAt,
                    status: .active)
                else {
                    throw StorageError.invalidDerivedMaintenanceJob(
                        "memory graph commitment candidate violates exact filter")
                }
                guard let primary = evidence.first else {
                    hydration.unavailableCount += 1
                    continue
                }
                hydration.facts.append(MeetingMemoryGraphFact(
                    id: .commitment(commitmentID),
                    kind: .personCommittedTo,
                    subject: .person(person.id),
                    object: .commitment(commitmentID),
                    subjectText: person.preferredName,
                    objectText: continuity.commitment.title,
                    status: .active,
                    occurredAt: occurredAt,
                    evidence: evidence,
                    primaryEvidenceSegmentID: primary.segmentID))
            case .stale:
                hydration.staleCount += 1
            case .unavailable:
                hydration.unavailableCount += 1
            }
        }
        return hydration
    }

    private static func currentCommitmentAuthority(
        _ continuity: CommitmentContinuityEnvelope,
        in database: Database
    ) throws -> PersonCommitmentAuthorityStatus {
        let sourceStatus = bestTimelineEvidence(try continuity.sources.map {
            try timelineEvidence(for: $0, in: database)
        })
        guard let latestReassignment = continuity.events.last(where: {
            $0.kind == .reassign
        }) else {
            return sourceStatus.personCommitmentAuthority(
                occurredAt: continuity.commitment.createdAt)
        }
        guard latestReassignment.assignee == continuity.commitment.assignee else {
            throw StorageError.invalidDerivedMaintenanceJob(
                "latest commitment reassignment disagrees with authority")
        }
        guard let reassignmentSource = latestReassignment.evidence else {
            return .unavailable
        }
        let reassignmentStatus = try timelineEvidence(
            for: reassignmentSource,
            in: database)
        switch (sourceStatus, reassignmentStatus) {
        case (.current(let sourceEvidence), .current(let reassignmentEvidence)):
            return .current(
                evidence: uniquePersonCommitmentEvidence(
                    reassignmentEvidence + sourceEvidence),
                occurredAt: latestReassignment.occurredAt)
        case (.unavailable, _), (_, .unavailable):
            return .unavailable
        case (.stale, _), (_, .stale):
            return .stale
        }
    }

    private static func uniquePersonCommitmentEvidence(
        _ evidence: [MeetingMemoryGraphEvidence]
    ) -> [MeetingMemoryGraphEvidence] {
        var seenSegmentIDs: Set<UUID> = []
        return evidence.filter {
            seenSegmentIDs.insert($0.segmentID).inserted
        }
    }
}

private extension MeetingStore.TimelineEvidenceStatus {
    func personCommitmentAuthority(
        occurredAt: Date
    ) -> PersonCommitmentAuthorityStatus {
        switch self {
        case .current(let evidence):
            .current(evidence: evidence, occurredAt: occurredAt)
        case .stale:
            .stale
        case .unavailable:
            .unavailable
        }
    }
}

private enum PersonCommitmentAuthorityStatus {
    case current(evidence: [MeetingMemoryGraphEvidence], occurredAt: Date)
    case stale
    case unavailable
}

private struct PersonCommitmentHydration {
    var facts: [MeetingMemoryGraphFact] = []
    var staleCount = 0
    var unavailableCount = 0
}

private struct PersonCommitmentCandidates {
    let keys: [String]
    let exceededBudget: Bool
}
