import Foundation
import GRDB
import PortavozCore

/// Who said the cited lines of one meeting, as its corrected transcript reads.
public struct AskCitedLines: Sendable, Equatable {
    public let startedAt: Date
    /// The speaker of each requested line or accepted segment still heard.
    public let speakers: [UUID: SpeakerID]

    public init(startedAt: Date, speakers: [UUID: SpeakerID]) {
        self.startedAt = startedAt
        self.speakers = speakers
    }
}

extension MeetingStore {
    /// Read on demand for an Ask answer's few meetings. Attribution follows
    /// the voice strip's; tombstoned meetings are absent.
    public func askCitedLines(_ lines: [MeetingID: [UUID]]) async throws -> [MeetingID: AskCitedLines] {
        guard !lines.isEmpty else { return [:] }
        return try await database.read { db in
            var cited: [MeetingID: AskCitedLines] = [:]
            for (meetingID, ids) in lines {
                guard let startedAt = try Date.fetchOne(
                    db, sql: "SELECT startedAt FROM meeting WHERE id = ? AND deletedAt IS NULL",
                    arguments: [meetingID.rawValue.uuidString])
                else { continue }
                let transcript = try Self.readableTranscript(in: db, for: meetingID)
                var speakers: [UUID: SpeakerID] = [:]
                for id in ids {
                    speakers[id] = transcript.lines[id] ?? transcript.segments[id]?.speaker
                }
                cited[meetingID] = AskCitedLines(startedAt: startedAt, speakers: speakers)
            }
            return cited
        }
    }
}
