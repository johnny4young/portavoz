import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Installs a completed imported meeting, cast, and transcript in one
    /// transaction. A child failure cannot expose a partial library entry.
    public func saveImportedMeeting(
        _ meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) async throws {
        if let path = meeting.audioDirectory { try StoredAudioPath.validate(path) }
        let meetingID = meeting.id
        let speakerIDs = Set(speakers.map(\.id))
        guard speakers.allSatisfy({ $0.meetingID == meetingID }) else {
            throw StorageError.invalidImportedMeeting("speaker belongs to another meeting")
        }
        guard segments.allSatisfy({ segment in
            segment.meetingID == meetingID
                && segment.speakerID.map(speakerIDs.contains) ?? true
        }) else {
            throw StorageError.invalidImportedMeeting(
                "segment belongs to another meeting or references an unknown speaker")
        }

        try await database.write { db in
            let timestamp = Date()
            try MeetingRecord(
                meeting,
                createdAt: timestamp,
                updatedAt: timestamp)
                .insert(db)
            for speaker in speakers {
                try SpeakerRecord(
                    speaker,
                    createdAt: timestamp,
                    updatedAt: timestamp)
                    .insert(db)
            }
            for segment in segments {
                try SegmentRecord(
                    segment,
                    createdAt: timestamp,
                    updatedAt: timestamp)
                    .insert(db)
            }
        }
    }
}
