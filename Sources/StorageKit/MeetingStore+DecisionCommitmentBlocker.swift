import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    public func confirmDecisionCommitmentBlocker(
        _ confirmation: DecisionCommitmentBlockerConfirmation
    ) async throws -> DecisionCommitmentBlockerContinuity {
        try await database.write { database in
            if try DecisionCommitmentBlockerRecord.fetchOne(
                database,
                key: confirmation.blockerID.rawValue.uuidString
            ) != nil {
                return try Self.replayDecisionCommitmentBlocker(
                    confirmation,
                    in: database)
            }
            let existingPair = try DecisionCommitmentBlockerRecord
                .filter(Column("decisionID") == confirmation.decisionID.rawValue.uuidString)
                .filter(Column("commitmentID") == confirmation.commitmentID.rawValue.uuidString)
                .fetchOne(database)
            guard existingPair == nil else {
                throw StorageError.invalidDecisionCommitmentBlocker(
                    "decision and commitment already have blocker authority")
            }
            try Self.validateBlockerEndpoints(
                decisionID: confirmation.decisionID,
                commitmentID: confirmation.commitmentID,
                in: database)
            try Self.validateBlockerEvidence(confirmation.evidence, in: database)
            let timestamp = Self.canonicalBlockerDate(confirmation.confirmedAt)
            let blocker = try DecisionCommitmentBlockerPolicy.projectedBlocker(
                id: confirmation.blockerID,
                decisionID: confirmation.decisionID,
                commitmentID: confirmation.commitmentID,
                openingEvidence: confirmation.evidence,
                confirmedAt: timestamp,
                events: [])
            let continuity = try DecisionCommitmentBlockerContinuity(
                blocker: blocker,
                openingEvidence: confirmation.evidence,
                events: [])
            try DecisionCommitmentBlockerRecord(
                blocker: blocker,
                openingEvidence: confirmation.evidence)
                .insert(database)
            try Self.insertBlockerEvidence(
                Array(confirmation.evidence.segmentIDs.dropFirst()),
                blockerID: confirmation.blockerID,
                in: database)
            return continuity
        }
    }

    public func applyDecisionCommitmentBlockerTransition(
        _ confirmation: DecisionBlockerTransitionConfirmation
    ) async throws -> DecisionCommitmentBlockerContinuity {
        try await database.write { database in
            let current = try Self.loadDecisionCommitmentBlockerContinuity(
                confirmation.blockerID,
                in: database)
            if let index = current.events.firstIndex(where: {
                $0.id == confirmation.eventID
            }) {
                return try Self.replayBlockerEvent(
                    confirmation,
                    current: current,
                    eventIndex: index)
            }
            guard try DecisionCommitmentBlockerEventRecord.fetchOne(
                database,
                key: confirmation.eventID.rawValue.uuidString
            ) == nil else {
                throw StorageError.invalidDecisionCommitmentBlocker(
                    "blocker event identity belongs to different history")
            }
            if confirmation.transition == .reopen {
                try Self.validateBlockerEndpoints(
                    decisionID: current.blocker.decisionID,
                    commitmentID: current.blocker.commitmentID,
                    in: database)
            }
            try Self.validateBlockerEvidence(confirmation.evidence, in: database)
            let requested = Self.canonicalBlockerDate(confirmation.confirmedAt)
            let occurredAt = requested > current.blocker.updatedAt
                ? requested
                : current.blocker.updatedAt.addingTimeInterval(0.001)
            let event = DecisionCommitmentBlockerEvent(
                id: confirmation.eventID,
                blockerID: confirmation.blockerID,
                kind: confirmation.transition.eventKind,
                evidence: confirmation.evidence,
                occurredAt: occurredAt)
            let events = current.events + [event]
            let blocker = try Self.projectBlocker(
                current: current,
                events: events)
            try DecisionCommitmentBlockerEventRecord(event).insert(database)
            try Self.insertBlockerEventEvidence(
                Array(event.evidence.segmentIDs.dropFirst()),
                eventID: event.id,
                in: database)
            return try DecisionCommitmentBlockerContinuity(
                blocker: blocker,
                openingEvidence: current.openingEvidence,
                events: events)
        }
    }

    public func decisionCommitmentBlockerContinuity(
        for blockerID: DecisionCommitmentBlockerID
    ) async throws -> DecisionCommitmentBlockerContinuity {
        try await database.read { database in
            try Self.loadDecisionCommitmentBlockerContinuity(blockerID, in: database)
        }
    }

    public func activeDecisionCommitmentBlockers(
        for commitmentID: CommitmentID
    ) async throws -> [DecisionCommitmentBlockerContinuity] {
        try await database.read { database in
            let keys = try String.fetchAll(
                database,
                sql: """
                    SELECT blocker.id
                    FROM decisionCommitmentBlocker AS blocker
                    JOIN decisionContinuity AS decision ON decision.id = blocker.decisionID
                    JOIN commitment ON commitment.id = blocker.commitmentID
                    WHERE blocker.commitmentID = ?
                      AND blocker.status = 'active'
                      AND blocker.deletedAt IS NULL
                      AND decision.status = 'confirmed'
                      AND decision.deletedAt IS NULL
                      AND commitment.status = 'confirmed'
                      AND commitment.deletedAt IS NULL
                    ORDER BY blocker.confirmedAt, blocker.id
                    """,
                arguments: [commitmentID.rawValue.uuidString])
            return try keys.map { key in
                try Self.loadDecisionCommitmentBlockerContinuity(
                    DecisionCommitmentBlockerID(
                        rawValue: try PersistedIdentity.required(
                            key,
                            table: DecisionCommitmentBlockerRecord.databaseTableName,
                            column: "id")),
                    in: database)
            }
        }
    }

    static func loadDecisionCommitmentBlockerContinuity(
        _ blockerID: DecisionCommitmentBlockerID,
        in database: Database
    ) throws -> DecisionCommitmentBlockerContinuity {
        let key = blockerID.rawValue.uuidString
        guard let record = try DecisionCommitmentBlockerRecord.fetchOne(
            database,
            key: key),
              record.deletedAt == nil
        else {
            throw StorageError.invalidDecisionCommitmentBlocker(
                "blocker identity is unavailable")
        }
        let openingSegments = try BlockerEvidenceSegmentRecord
            .filter(Column("blockerID") == key)
            .order(Column("ordinal"))
            .fetchAll(database)
            .map { try $0.persistedSegmentID }
        let eventRecords = try DecisionCommitmentBlockerEventRecord
            .filter(Column("blockerID") == key)
            .order(Column("occurredAt"), Column("id"))
            .fetchAll(database)
        let events = try eventRecords.map { eventRecord in
            let segmentIDs = try BlockerEventEvidenceSegmentRecord
                .filter(Column("eventID") == eventRecord.id)
                .order(Column("ordinal"))
                .fetchAll(database)
                .map { try $0.persistedSegmentID }
            return try eventRecord.event(additionalSegmentIDs: segmentIDs)
        }
        do {
            return try DecisionCommitmentBlockerContinuity(
                blocker: record.blocker(),
                openingEvidence: record.openingEvidence(
                    additionalSegmentIDs: openingSegments),
                events: events)
        } catch let error as DecisionCommitmentBlockerValidationError {
            throw StorageError.invalidDecisionCommitmentBlocker(
                String(describing: error))
        }
    }
}

private extension MeetingStore {
    static func replayDecisionCommitmentBlocker(
        _ confirmation: DecisionCommitmentBlockerConfirmation,
        in database: Database
    ) throws -> DecisionCommitmentBlockerContinuity {
        let existing = try loadDecisionCommitmentBlockerContinuity(
            confirmation.blockerID,
            in: database)
        guard existing.blocker.decisionID == confirmation.decisionID,
              existing.blocker.commitmentID == confirmation.commitmentID,
              existing.blocker.confirmedAt == canonicalBlockerDate(
                  confirmation.confirmedAt),
              existing.openingEvidence == confirmation.evidence
        else {
            throw StorageError.invalidDecisionCommitmentBlocker(
                "blocker identity conflicts with persisted authority")
        }
        return existing
    }

    static func replayBlockerEvent(
        _ confirmation: DecisionBlockerTransitionConfirmation,
        current: DecisionCommitmentBlockerContinuity,
        eventIndex: Int
    ) throws -> DecisionCommitmentBlockerContinuity {
        let existing = current.events[eventIndex]
        let predecessor = eventIndex == current.events.startIndex
            ? current.blocker.confirmedAt
            : current.events[current.events.index(before: eventIndex)].occurredAt
        let requested = canonicalBlockerDate(confirmation.confirmedAt)
        let expected = requested > predecessor
            ? requested
            : predecessor.addingTimeInterval(0.001)
        guard existing.blockerID == confirmation.blockerID,
              existing.kind == confirmation.transition.eventKind,
              existing.evidence == confirmation.evidence,
              blockerMilliseconds(existing.occurredAt) == blockerMilliseconds(expected)
        else {
            throw StorageError.invalidDecisionCommitmentBlocker(
                "blocker event identity conflicts with persisted history")
        }
        return current
    }

    static func projectBlocker(
        current: DecisionCommitmentBlockerContinuity,
        events: [DecisionCommitmentBlockerEvent]
    ) throws -> DecisionCommitmentBlocker {
        do {
            return try DecisionCommitmentBlockerPolicy.projectedBlocker(
                id: current.blocker.id,
                decisionID: current.blocker.decisionID,
                commitmentID: current.blocker.commitmentID,
                openingEvidence: current.openingEvidence,
                confirmedAt: current.blocker.confirmedAt,
                events: events)
        } catch let error as DecisionCommitmentBlockerValidationError {
            throw StorageError.invalidDecisionCommitmentBlocker(
                String(describing: error))
        }
    }

    static func validateBlockerEndpoints(
        decisionID: DecisionID,
        commitmentID: CommitmentID,
        in database: Database
    ) throws {
        let valid = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS (
                    SELECT 1
                    FROM decisionContinuity AS decision
                    JOIN commitment ON commitment.id = ?
                    WHERE decision.id = ?
                      AND decision.status = 'confirmed'
                      AND decision.deletedAt IS NULL
                      AND commitment.status = 'confirmed'
                      AND commitment.deletedAt IS NULL
                )
                """,
            arguments: [
                commitmentID.rawValue.uuidString,
                decisionID.rawValue.uuidString
            ]) ?? false
        guard valid else {
            throw StorageError.invalidDecisionCommitmentBlocker(
                "blocker endpoints must be current confirmed authority")
        }
    }

    static func validateBlockerEvidence(
        _ evidence: DecisionCommitmentBlockerEvidence,
        in database: Database
    ) throws {
        guard evidence.sourceTranscriptRevision >= 0,
              !evidence.segmentIDs.isEmpty,
              Set(evidence.segmentIDs).count == evidence.segmentIDs.count,
              let meeting = try MeetingRecord.fetchOne(
                  database,
                  key: evidence.meetingID.rawValue.uuidString),
              meeting.deletedAt == nil,
              meeting.transcriptRevision == evidence.sourceTranscriptRevision
        else {
            throw StorageError.invalidDecisionCommitmentBlocker(
                "blocker evidence is stale or unavailable")
        }
        let keys = evidence.segmentIDs.map(\.uuidString)
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        let count = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM segment
                WHERE id IN (\(placeholders))
                  AND meetingID = ?
                  AND deletedAt IS NULL
                  AND isFinal = 1
                  AND \(acceptedSegmentHasNoActiveCorrectionSQL)
                """,
            arguments: StatementArguments(
                keys + [evidence.meetingID.rawValue.uuidString])) ?? 0
        guard count == keys.count else {
            throw StorageError.invalidDecisionCommitmentBlocker(
                "blocker evidence is stale or unavailable")
        }
    }

    static func insertBlockerEvidence(
        _ segmentIDs: [UUID],
        blockerID: DecisionCommitmentBlockerID,
        in database: Database
    ) throws {
        for (index, segmentID) in segmentIDs.enumerated() {
            try BlockerEvidenceSegmentRecord(
                blockerID: blockerID,
                segmentID: segmentID,
                ordinal: index + 1)
                .insert(database)
        }
    }

    static func insertBlockerEventEvidence(
        _ segmentIDs: [UUID],
        eventID: DecisionCommitmentBlockerEventID,
        in database: Database
    ) throws {
        for (index, segmentID) in segmentIDs.enumerated() {
            try BlockerEventEvidenceSegmentRecord(
                eventID: eventID,
                segmentID: segmentID,
                ordinal: index + 1)
                .insert(database)
        }
    }

    static func canonicalBlockerDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: Double(blockerMilliseconds(date)) / 1_000)
    }

    static func blockerMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
