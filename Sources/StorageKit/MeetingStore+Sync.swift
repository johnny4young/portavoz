import Foundation
import GRDB
import PortavozCore

/// Content-free notification that one meeting aggregate needs synchronization.
/// The generation is a compare-and-ack fence: acknowledging generation N can
/// never hide a local generation N+1 that arrived while a send was in flight.
public struct MeetingSyncChange: Equatable, Sendable, Identifiable {
    public let meetingID: MeetingID
    public let generation: Int
    public let changedAt: Date
    public let isDeleted: Bool

    public var id: MeetingID { meetingID }

    public init(
        meetingID: MeetingID,
        generation: Int,
        changedAt: Date,
        isDeleted: Bool
    ) {
        self.meetingID = meetingID
        self.generation = generation
        self.changedAt = changedAt
        self.isDeleted = isDeleted
    }
}

/// One committed checkpoint while an existing library is admitted to sync.
/// The opaque meeting identity is a durable cursor owned by the transport
/// policy; no meeting content crosses this boundary.
public struct MeetingInitialSyncSeedBatch: Equatable, Sendable {
    public let processedCount: Int
    public let lastMeetingID: MeetingID?
    public let isComplete: Bool

    public init(
        processedCount: Int,
        lastMeetingID: MeetingID?,
        isComplete: Bool
    ) {
        self.processedCount = processedCount
        self.lastMeetingID = lastMeetingID
        self.isComplete = isComplete
    }
}

extension MeetingStore {
    /// Marks one deterministic batch after explicit existing-library opt-in.
    /// Replaying a committed batch is idempotent while its rows remain pending,
    /// which closes the cross-store crash window before the transport cursor
    /// is published.
    @discardableResult
    public func markMeetingsForInitialSync(
        after cursor: MeetingID?,
        limit: Int = 100
    ) async throws -> MeetingInitialSyncSeedBatch {
        guard limit > 0 else {
            throw StorageError.invalidSyncState("initial seed limit must be positive")
        }
        return try await database.write { db in
            let cursorValue = cursor?.rawValue.uuidString
            let rows = try InitialSyncMeetingRecord.fetchAll(
                db,
                sql: """
                    SELECT id, updatedAt, deletedAt
                      FROM meeting
                     WHERE (? IS NULL OR id > ?)
                     ORDER BY id
                     LIMIT ?
                    """,
                arguments: [cursorValue, cursorValue, limit])
            for row in rows {
                try db.execute(
                    sql: """
                        INSERT INTO meetingSyncState (
                            meetingID, localGeneration, acknowledgedGeneration,
                            changedAt, isDeleted
                        )
                        VALUES (?, 1, 0, ?, ?)
                        ON CONFLICT(meetingID) DO UPDATE SET
                            localGeneration = CASE
                                WHEN meetingSyncState.localGeneration
                                    > meetingSyncState.acknowledgedGeneration
                                THEN meetingSyncState.localGeneration
                                ELSE meetingSyncState.localGeneration + 1
                            END,
                            changedAt = MAX(
                                meetingSyncState.changedAt,
                                excluded.changedAt
                            ),
                            isDeleted = excluded.isDeleted
                        """,
                    arguments: [row.id, row.updatedAt, row.deletedAt != nil])
            }
            return MeetingInitialSyncSeedBatch(
                processedCount: rows.count,
                lastMeetingID: try rows.last?.meetingID,
                isComplete: rows.count < limit)
        }
    }

    public func pendingMeetingSyncChanges(limit: Int = 100) async throws -> [MeetingSyncChange] {
        guard limit > 0 else {
            throw StorageError.invalidSyncState("pending limit must be positive")
        }
        return try await database.read { db in
            try MeetingSyncStateRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM meetingSyncState
                     WHERE localGeneration > acknowledgedGeneration
                     ORDER BY changedAt, meetingID
                     LIMIT ?
                    """,
                arguments: [limit])
                .map { try $0.syncChange }
        }
    }

    /// Acknowledges only the generation actually sent. If a newer local edit
    /// arrived meanwhile, it remains pending by construction.
    public func acknowledgeMeetingSync(_ change: MeetingSyncChange) async throws {
        guard change.generation > 0 else {
            throw StorageError.invalidSyncState("acknowledged generation must be positive")
        }
        try await database.write { db in
            let key = change.meetingID.rawValue.uuidString
            guard var record = try MeetingSyncStateRecord.fetchOne(db, key: key) else {
                throw StorageError.invalidSyncState("acknowledged meeting has no journal state")
            }
            guard change.generation <= record.localGeneration else {
                throw StorageError.invalidSyncState(
                    "acknowledged generation is newer than local state")
            }
            record.acknowledgedGeneration = max(
                record.acknowledgedGeneration,
                change.generation)
            try record.update(db)
        }
    }
}

private struct InitialSyncMeetingRecord: FetchableRecord, Decodable {
    let id: String
    let updatedAt: Date
    let deletedAt: Date?

    var meetingID: MeetingID {
        get throws {
            MeetingID(rawValue: try PersistedIdentity.required(
                id,
                table: MeetingRecord.databaseTableName,
                column: "id"))
        }
    }
}

private extension MeetingSyncStateRecord {
    var syncChange: MeetingSyncChange {
        get throws {
            MeetingSyncChange(
                meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                    meetingID,
                    table: Self.databaseTableName,
                    column: "meetingID")),
                generation: localGeneration,
                changedAt: changedAt,
                isDeleted: isDeleted)
        }
    }
}
