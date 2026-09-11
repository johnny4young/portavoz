import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Acknowledgement means the canonical rows committed. Stop may add missing
    /// snapshot rows, but can never overwrite these edits or their tombstones.
    public func persistRecordingInput(
        _ items: [ContextItem],
        removing removedIDs: [UUID],
        for meetingID: MeetingID
    ) async throws {
        guard Set(items.map(\.id)).count == items.count,
              Set(removedIDs).isDisjoint(with: items.map(\.id)),
              items.allSatisfy({
                  $0.meetingID == meetingID && $0.timestamp.isFinite && $0.timestamp >= 0
                      && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              })
        else { throw StorageError.invalidRecordingReservation("invalid live input") }
        try Task.checkCancellation()
        try await database.write { db in
            let key = meetingID.rawValue.uuidString
            guard let meeting = try MeetingRecord.fetchOne(db, key: key),
                  meeting.deletedAt == nil, meeting.endedAt == nil,
                  meeting.lifecycleState == MeetingLifecycleState.recording.rawValue
            else { throw StorageError.invalidRecordingReservation("live input requires active recording") }
            let now = Date()
            for item in items {
                let existing = try ContextItemRecord.fetchOne(db, key: item.id.uuidString)
                if let existing {
                    guard existing.meetingID == key, existing.kind == item.kind.rawValue,
                          existing.deletedAt == nil
                    else { throw StorageError.invalidRecordingReservation("live input identity changed") }
                }
                try ContextItemRecord(item, createdAt: existing?.createdAt ?? now, updatedAt: now).save(db)
            }
            for id in removedIDs {
                guard var existing = try ContextItemRecord.fetchOne(db, key: id.uuidString) else { continue }
                guard existing.meetingID == key else {
                    throw StorageError.invalidRecordingReservation("live input belongs to another meeting")
                }
                if existing.deletedAt == nil {
                    existing.deletedAt = now
                    existing.updatedAt = now
                    try existing.update(db)
                }
            }
        }
    }

    /// Includes tombstones: even a stale Stop payload must not resurrect a
    /// removed input, and a content-bearing shell must not be hard-deleted.
    public func hasRecordingInput(for meetingID: MeetingID) async throws -> Bool {
        try await database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM contextItem WHERE meetingID = ?)",
                              arguments: [meetingID.rawValue.uuidString]) ?? false
        }
    }

    static func insertUnpersistedRecordingInput(
        _ items: [ContextItem], at timestamp: Date, in db: Database
    ) throws {
        for item in items {
            if let existing = try ContextItemRecord.fetchOne(db, key: item.id.uuidString) {
                guard existing.meetingID == item.meetingID.rawValue.uuidString,
                      existing.kind == item.kind.rawValue
                else { throw StorageError.invalidRecordingReservation("snapshot input identity changed") }
                // The persisted edit/removal is authoritative, not this older
                // in-memory snapshot or a deliberately empty recovery payload.
                continue
            }
            try ContextItemRecord(item, createdAt: timestamp, updatedAt: timestamp).insert(db)
        }
    }
}
