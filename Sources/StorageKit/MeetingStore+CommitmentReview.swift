import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Persists only the user's current treatment of one active generated
    /// source. It never copies generated text, owner, deadline, or evidence.
    public func setCommitmentReviewDecision(
        _ disposition: CommitmentReviewDisposition?,
        for actionItemID: UUID,
        meetingID: MeetingID,
        revisitAt proposedRevisitAt: Date? = nil,
        at proposedDate: Date = Date()
    ) async throws {
        try await database.write { database in
            let proposedTimestamp = Self.canonicalCommitmentDate(proposedDate)
            try Self.validateActiveCommitmentSource(
                actionItemID,
                meetingID: meetingID,
                in: database)
            guard try Self.confirmedCommitment(
                actionItemID: actionItemID,
                in: database) == nil
            else {
                throw StorageError.invalidCommitment(
                    "a confirmed source cannot retain inbox feedback")
            }
            let timestamp = try Self.commitmentReviewMutationDate(
                actionItemID: actionItemID,
                proposed: proposedTimestamp,
                in: database)
            guard let disposition else {
                try Self.clearCommitmentReviewDecision(
                    actionItemID: actionItemID,
                    at: timestamp,
                    in: database)
                return
            }
            let revisitAt = proposedRevisitAt.map(Self.canonicalCommitmentDate)
            if disposition == .deferred {
                guard let revisitAt, revisitAt > timestamp else {
                    throw StorageError.invalidCommitment(
                        "a deferred source requires a future revisit date")
                }
            }
            let decision = CommitmentReviewDecision(
                actionItemID: actionItemID,
                disposition: disposition,
                revisitAt: revisitAt,
                updatedAt: timestamp)
            do {
                try CommitmentReviewPolicy.validate(decision)
            } catch {
                throw StorageError.invalidCommitment(String(describing: error))
            }
            try Self.persistCommitmentReviewDecision(decision, in: database)
        }
    }

    /// One bounded, read-consistent inbox reconciliation for the newest
    /// summary. Missing state is represented by the caller's ActionItem list.
    public func commitmentReviewStates(
        for meetingID: MeetingID
    ) async throws -> [CommitmentReviewState] {
        try await database.read { database in
            try Self.commitmentReviewStates(for: meetingID, in: database)
        }
    }

    public func observeCommitmentReviewStates(
        for meetingID: MeetingID
    ) -> AsyncThrowingStream<[CommitmentReviewState], Error> {
        let observation = ValueObservation.tracking(
            regions: [
                Table("meeting"), Table("summary"), Table("actionItem"),
                Table("commitmentReviewDecision"), Table("commitmentSource"),
                Table("commitment")
            ],
            fetch: { database in
                try Self.commitmentReviewStates(for: meetingID, in: database)
            })
        return observedStream(observation)
    }
}

extension MeetingStore {
    static func clearCommitmentReviewDecision(
        actionItemID: UUID,
        at timestamp: Date,
        in database: Database
    ) throws {
        guard var record = try CommitmentReviewDecisionRecord.fetchOne(
            database,
            key: actionItemID.uuidString),
              record.deletedAt == nil
        else { return }
        let effectiveTimestamp = max(timestamp, record.createdAt, record.updatedAt)
        record.revisitAt = nil
        record.updatedAt = effectiveTimestamp
        record.deletedAt = effectiveTimestamp
        try record.update(database)
    }

    static func validateActiveCommitmentSource(
        _ actionItemID: UUID,
        meetingID: MeetingID,
        in database: Database
    ) throws {
        let meetingKey = meetingID.rawValue.uuidString
        let sourceIsActive = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS (
                    SELECT 1
                    FROM actionItem AS item
                    JOIN summary AS artifact ON artifact.id = item.summaryID
                    WHERE item.id = ?
                      AND item.meetingID = ?
                      AND item.deletedAt IS NULL
                      AND artifact.deletedAt IS NULL
                      AND artifact.rowid = (
                          SELECT rowid
                          FROM summary
                          WHERE meetingID = ? AND deletedAt IS NULL
                          ORDER BY createdAt DESC, rowid DESC
                          LIMIT 1
                      )
                )
                """,
            arguments: [actionItemID.uuidString, meetingKey, meetingKey]) ?? false
        guard sourceIsActive else {
            throw StorageError.invalidCommitment(
                "commitment source requires an ActionItem in the active summary")
        }
    }
}

private extension MeetingStore {
    static func persistCommitmentReviewDecision(
        _ decision: CommitmentReviewDecision,
        in database: Database
    ) throws {
        if var record = try CommitmentReviewDecisionRecord.fetchOne(
            database,
            key: decision.actionItemID.uuidString) {
            record.disposition = decision.disposition.rawValue
            record.revisitAt = decision.revisitAt
            record.updatedAt = decision.updatedAt
            record.deletedAt = nil
            try record.update(database)
        } else {
            try CommitmentReviewDecisionRecord(
                decision,
                createdAt: decision.updatedAt)
                .insert(database)
        }
    }

    static func commitmentReviewMutationDate(
        actionItemID: UUID,
        proposed timestamp: Date,
        in database: Database
    ) throws -> Date {
        guard let record = try CommitmentReviewDecisionRecord.fetchOne(
            database,
            key: actionItemID.uuidString)
        else { return timestamp }
        return max(timestamp, record.createdAt, record.updatedAt)
    }

    static func commitmentReviewStates(
        for meetingID: MeetingID,
        in database: Database
    ) throws -> [CommitmentReviewState] {
        let meetingKey = meetingID.rawValue.uuidString
        guard try commitmentReviewMeetingExists(meetingID, in: database),
              let summary = try SummaryRecord
                .filter(Column("meetingID") == meetingKey)
                .filter(Column("deletedAt") == nil)
                .order(Column("createdAt").desc, Column.rowID.desc)
                .fetchOne(database)
        else { return [] }

        let itemRecords = try ActionItemRecord
            .filter(Column("summaryID") == summary.id)
            .filter(Column("deletedAt") == nil)
            .order(Column("createdAt"), Column.rowID)
            .fetchAll(database)
        let itemIDs = itemRecords.map(\.id)
        guard !itemIDs.isEmpty else { return [] }

        let reviewRecords = try CommitmentReviewDecisionRecord
            .filter(itemIDs.contains(Column("actionItemID")))
            .filter(Column("deletedAt") == nil)
            .fetchAll(database)
        let decisions = try Dictionary(
            uniqueKeysWithValues: reviewRecords.map { record in
                let decision = try record.decision
                return (decision.actionItemID, decision)
            })
        let sourceRecords = try CommitmentSourceRecord
            .filter(itemIDs.contains(Column("actionItemID")))
            .filter(Column("kind") == CommitmentSourceKind.generatedActionItem.rawValue)
            .fetchAll(database)
        let commitmentKeys = sourceRecords.map(\.commitmentID)
        let commitments = try CommitmentRecord
            .filter(commitmentKeys.contains(Column("id")))
            .filter(Column("deletedAt") == nil)
            .fetchAll(database)
            .reduce(into: [String: Commitment]()) { result, record in
                result[record.id] = try record.commitment
            }
        let commitmentByItem = sourceRecords.reduce(
            into: [UUID: Commitment]()) { result, source in
                guard let itemID = source.actionItemID.flatMap(UUID.init(uuidString:)),
                      let commitment = commitments[source.commitmentID]
                else { return }
                result[itemID] = commitment
        }

        return try itemRecords.map { record in
            let item = try record.actionItem
            let state = CommitmentReviewState(
                actionItemID: item.id,
                decision: decisions[item.id],
                commitment: commitmentByItem[item.id])
            do {
                try CommitmentReviewPolicy.validate(state)
                return state
            } catch {
                throw StorageError.invalidCommitment(
                    "persisted inbox state failed validation: \(error)")
            }
        }
    }

    static func commitmentReviewMeetingExists(
        _ meetingID: MeetingID,
        in database: Database
    ) throws -> Bool {
        try MeetingRecord
            .filter(Column("id") == meetingID.rawValue.uuidString)
            .filter(Column("deletedAt") == nil)
            .fetchCount(database) > 0
    }
}

extension MeetingStore {
    static func confirmedCommitment(
        actionItemID: UUID,
        in database: Database
    ) throws -> Commitment? {
        guard let source = try CommitmentSourceRecord
            .filter(Column("actionItemID") == actionItemID.uuidString)
            .filter(Column("kind") == CommitmentSourceKind.generatedActionItem.rawValue)
            .fetchOne(database),
              let record = try CommitmentRecord
                .filter(Column("id") == source.commitmentID)
                .filter(Column("deletedAt") == nil)
                .fetchOne(database)
        else { return nil }
        return try record.commitment
    }
}
