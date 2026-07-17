import Foundation
import GRDB

public struct MeetingSyncJournalStatus: Equatable, Sendable {
    public let pendingCount: Int
    public let newestChangeAt: Date?

    public init(pendingCount: Int, newestChangeAt: Date?) {
        self.pendingCount = pendingCount
        self.newestChangeAt = newestChangeAt
    }
}

extension MeetingStore {
    public func meetingSyncJournalStatus() async throws -> MeetingSyncJournalStatus {
        try await database.read { db in
            try Self.fetchMeetingSyncJournalStatus(db)
        }
    }

    public func observeMeetingSyncJournalStatus(
    ) -> AsyncThrowingStream<MeetingSyncJournalStatus, Error> {
        let observation = ValueObservation.tracking { db in
            try Self.fetchMeetingSyncJournalStatus(db)
        }
        return observedStream(observation)
    }

    private static func fetchMeetingSyncJournalStatus(
        _ db: Database
    ) throws -> MeetingSyncJournalStatus {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) AS pendingCount,
                       MAX(changedAt) AS newestChangeAt
                  FROM meetingSyncState
                 WHERE localGeneration > acknowledgedGeneration
                """)
        return MeetingSyncJournalStatus(
            pendingCount: row?["pendingCount"] ?? 0,
            newestChangeAt: row?["newestChangeAt"])
    }
}
