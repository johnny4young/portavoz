import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// One speaker's slice of a meeting's attributed speech — the pieces of
    /// the sidebar's voice-mix bar (design system: "the library becomes a
    /// shelf of conversations you can read at a glance"). `order` is the
    /// speaker's rank by talk time, used to color unnamed speakers by
    /// appearance; named speakers color by their name instead.
    public struct VoiceMixSlice: Sendable, Equatable {
        public let isMe: Bool
        public let displayName: String?
        public let fraction: Double
        public let order: Int
    }

    /// The voice mix for a set of meetings, in ONE aggregate query — sums
    /// segment durations per (meeting, speaker) and returns each meeting's
    /// slices, largest first, normalized to the meeting's attributed
    /// speech. Meetings with no attributed speech are simply absent.
    public func voiceMixes(
        for meetingIDs: [MeetingID]
    ) async throws -> [MeetingID: [VoiceMixSlice]] {
        guard !meetingIDs.isEmpty else { return [:] }
        let ids = meetingIDs.map { $0.rawValue.uuidString }
        return try await database.read { db in
            let placeholders = databaseQuestionMarks(count: ids.count)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT segment.meetingID AS meetingID,
                           speaker.isMe AS isMe,
                           speaker.displayName AS displayName,
                           SUM(segment.endTime - segment.startTime) AS seconds
                    FROM segment
                    JOIN speaker ON speaker.id = segment.speakerID
                        AND speaker.deletedAt IS NULL
                    WHERE segment.deletedAt IS NULL
                      AND segment.speakerID IS NOT NULL
                      AND segment.endTime > segment.startTime
                      AND segment.meetingID IN (\(placeholders))
                    GROUP BY segment.meetingID, segment.speakerID
                    ORDER BY segment.meetingID, seconds DESC
                    """,
                arguments: StatementArguments(ids))

            var byMeeting: [MeetingID: [(isMe: Bool, name: String?, seconds: Double)]] = [:]
            for row in rows {
                guard let uuid = UUID(uuidString: row["meetingID"]) else { continue }
                let id = MeetingID(rawValue: uuid)
                byMeeting[id, default: []].append(
                    (isMe: row["isMe"], name: row["displayName"], seconds: row["seconds"]))
            }

            var result: [MeetingID: [VoiceMixSlice]] = [:]
            for (id, speakers) in byMeeting {
                let total = speakers.reduce(0) { $0 + $1.seconds }
                guard total > 0 else { continue }
                result[id] = speakers.enumerated().map { order, speaker in
                    VoiceMixSlice(
                        isMe: speaker.isMe,
                        displayName: speaker.name,
                        fraction: speaker.seconds / total,
                        order: order)
                }
            }
            return result
        }
    }
}
