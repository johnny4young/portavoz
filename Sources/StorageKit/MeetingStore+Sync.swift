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

extension MeetingStore {
    /// Seeds every current meeting exactly when sync is enabled. Migration to
    /// v14 itself queues nothing, so upgrading an offline-only library remains
    /// a content-free, side-effect-free operation.
    @discardableResult
    public func markAllMeetingsForInitialSync() async throws -> Int {
        try await database.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting") ?? 0
            try db.execute(sql: """
                INSERT INTO meetingSyncState (
                    meetingID, localGeneration, acknowledgedGeneration, changedAt, isDeleted
                )
                SELECT id, 1, 0, updatedAt, deletedAt IS NOT NULL
                  FROM meeting
                 WHERE 1
                ON CONFLICT(meetingID) DO UPDATE SET
                    localGeneration = meetingSyncState.localGeneration + 1,
                    changedAt = excluded.changedAt,
                    isDeleted = excluded.isDeleted
                """)
            return count
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
