import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Creates durable decision continuity only after explicit confirmation of
    /// one current generated observation.
    public func confirmDecision(
        _ confirmation: DecisionConfirmation
    ) async throws -> DecisionContinuity {
        try await database.write { database in
            try Self.confirmObservedDecision(confirmation, in: database)
        }
    }

    /// Adds one explicitly accepted later observation without changing the
    /// stable statement or lifecycle of the current decision.
    public func linkDecisionSource(
        _ confirmation: DecisionSourceConfirmation
    ) async throws -> DecisionContinuity {
        try await database.write { database in
            try Self.confirmAdditionalDecisionSource(confirmation, in: database)
        }
    }

    /// Makes a newer confirmed decision explicitly supersede or reverse an
    /// older confirmed decision. The returned aggregate is the older target.
    public func confirmDecisionRelationship(
        _ confirmation: DecisionRelationshipConfirmation
    ) async throws -> DecisionContinuity {
        try await database.write { database in
            try Self.applyDecisionRelationship(confirmation, in: database)
        }
    }

    public func decisionContinuity(
        for decisionID: DecisionID
    ) async throws -> DecisionContinuity {
        try await database.read { database in
            try Self.loadDecisionContinuity(decisionID, in: database)
        }
    }

    static func loadDecisionContinuity(
        _ decisionID: DecisionID,
        in database: Database
    ) throws -> DecisionContinuity {
        let decisionKey = decisionID.rawValue.uuidString
        guard let record = try DecisionContinuityRecord.fetchOne(
            database,
            key: decisionKey),
              record.deletedAt == nil
        else {
            throw StorageError.invalidDecisionContinuity("decision is unavailable")
        }
        let sourceRecords = try DecisionContinuitySourceRecord
            .filter(Column("decisionID") == decisionKey)
            .order(
                Column("linkedAt"), Column("observedAt"),
                Column("meetingID"), Column("id"))
            .fetchAll(database)
        let sources = try sourceRecords.map { sourceRecord in
            let evidence = try DecisionContinuityEvidenceSegmentRecord
                .filter(Column("sourceID") == sourceRecord.id)
                .order(Column("ordinal"))
                .fetchAll(database)
                .map { try $0.evidence }
            return try sourceRecord.source(
                evidence: evidence,
                availability: try decisionEvidenceAvailability(
                    sourceRecord,
                    evidence: evidence,
                    in: database))
        }
        let events = try DecisionContinuityEventRecord
            .filter(Column("decisionID") == decisionKey)
            .order(Column("occurredAt"), Column("id"))
            .fetchAll(database)
            .map { try $0.event }
        do {
            return try DecisionContinuity(
                decision: record.decision,
                sources: sources,
                events: events)
        } catch let error as DecisionContinuityValidationError {
            throw StorageError.invalidDecisionContinuity(String(describing: error))
        }
    }

    static func canonicalDecisionDate(_ date: Date) -> Date {
        // GRDB persists these lifecycle timestamps at millisecond precision.
        // Round toward the future so a persisted confirmation can never appear
        // to predate the exact observation or user action that authorized it.
        let microseconds = Int64(
            (date.timeIntervalSince1970 * 1_000_000).rounded())
        let wholeMilliseconds = microseconds / 1_000
        let remainingMicroseconds = microseconds % 1_000
        let ceilingMilliseconds = wholeMilliseconds
            + (remainingMicroseconds > 0 ? 1 : 0)
        return Date(
            timeIntervalSince1970: Double(ceilingMilliseconds) / 1_000)
    }

    static func sameDecisionDate(_ lhs: Date, _ rhs: Date) -> Bool {
        canonicalDecisionDate(lhs) == canonicalDecisionDate(rhs)
    }
}
