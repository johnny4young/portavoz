import Foundation
import GRDB
import PortavozCore

// Audio-retention enforcement (closes the M1 deferral). Split out of
// `MeetingStore.swift` so the core type stays small.
extension MeetingStore {
    // MARK: - Audio retention

    /// One meeting eligible for audio-retention enforcement (named to avoid a
    /// large tuple; carries only what the sweep below needs).
    private struct RetentionCandidate {
        let meetingID: MeetingID
        let relativePath: String
        let policy: AudioRetentionPolicy
        let endedAt: Date?
        let hasTranscript: Bool
    }

    /// Applies each meeting's retention policy: deletes expired audio
    /// directories under `audioRoot` and clears their reference. Returns
    /// the URLs it removed. Transcripts are never touched — the policies
    /// only ever cover raw audio.
    @discardableResult
    public func enforceAudioRetention(audioRoot: URL, now: Date = Date()) async throws -> [URL] {
        let candidates: [RetentionCandidate] =
            try await database.read { db in
                let records = try MeetingRecord
                    .filter(Column("deletedAt") == nil)
                    .filter(Column("audioDirectory") != nil)
                    .fetchAll(db)
                return try records.map { record in
                    let hasTranscript =
                        try SegmentRecord
                        .filter(Column("meetingID") == record.id)
                        .filter(Column("deletedAt") == nil)
                        .filter(Column("isFinal") == true)
                        .fetchCount(db) > 0
                    return RetentionCandidate(
                        meetingID: MeetingID(rawValue: UUID(uuidString: record.id) ?? UUID()),
                        relativePath: record.audioDirectory ?? "",
                        policy: try MeetingRecord.decode(record.retention),
                        endedAt: record.endedAt,
                        hasTranscript: hasTranscript
                    )
                }
            }

        var removed: [URL] = []
        for candidate in candidates {
            let expired: Bool
            switch candidate.policy {
            case .keep:
                expired = false
            case .deleteAfter(let days):
                guard let endedAt = candidate.endedAt else { continue }
                expired = now >= endedAt.addingTimeInterval(TimeInterval(days) * 86_400)
            case .deleteAfterTranscription:
                expired = candidate.hasTranscript
            }
            guard expired else { continue }

            // Path-traversal guard: the resolved directory must stay under
            // the audio root.
            let directory = audioRoot.appendingPathComponent(candidate.relativePath).standardizedFileURL
            guard directory.path.hasPrefix(audioRoot.standardizedFileURL.path) else { continue }

            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            try await database.write { db in
                try db.execute(
                    sql: "UPDATE meeting SET audioDirectory = NULL, updatedAt = ? WHERE id = ?",
                    arguments: [Date(), candidate.meetingID.rawValue.uuidString])
            }
            removed.append(directory)
        }
        return removed
    }
}
