import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Saved listening positions for live meetings, in one read. Meetings never
    /// played and tombstoned meetings are absent.
    public func playbackPositions(
        for meetingIDs: [MeetingID]
    ) async throws -> [MeetingID: MeetingPlaybackPosition] {
        let ids = Array(Set(meetingIDs.map(\.rawValue.uuidString)))
        guard !ids.isEmpty else { return [:] }
        return try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT position.meetingID, position.positionSeconds, position.heardAt, position.updatedAt
                    FROM meetingPlaybackPosition position
                    JOIN meeting ON meeting.id = position.meetingID AND meeting.deletedAt IS NULL
                    WHERE position.meetingID IN (\(databaseQuestionMarks(count: ids.count)))
                    """,
                arguments: StatementArguments(ids))
            var positions: [MeetingID: MeetingPlaybackPosition] = [:]
            for row in rows {
                let id = MeetingID(rawValue: try PersistedIdentity.required(
                    row["meetingID"], table: "meetingPlaybackPosition", column: "meetingID"))
                let heardAt: Date? = row["heardAt"]
                positions[id] = MeetingPlaybackPosition(
                    meetingID: id, seconds: row["positionSeconds"], isHeard: heardAt != nil,
                    updatedAt: row["updatedAt"])
            }
            return positions
        }
    }

    /// Records where listening stopped; the last write wins, so callers save in
    /// order. A meeting once heard to the end stays heard.
    public func savePlaybackPosition(_ position: MeetingPlaybackPosition) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meetingPlaybackPosition (meetingID, positionSeconds, heardAt, updatedAt)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(meetingID) DO UPDATE SET
                        positionSeconds = excluded.positionSeconds,
                        heardAt = COALESCE(meetingPlaybackPosition.heardAt, excluded.heardAt),
                        updatedAt = excluded.updatedAt
                    """,
                arguments: [
                    position.meetingID.rawValue.uuidString, position.seconds,
                    position.isHeard ? position.updatedAt : nil, position.updatedAt
                ])
        }
    }
}
