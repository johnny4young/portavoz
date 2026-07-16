import Foundation
import GRDB
import PortavozCore

/// One internal shape for first-pass transcription and diarization artifacts.
/// Both stages replace the complete live cast and advance the transcript
/// revision under the same storage invariants.
struct TranscriptArtifactEnvelope {
    let meetingID: MeetingID
    let inputFingerprint: String
    let sourceTranscriptRevision: Int
    let language: String?
    let speakers: [Speaker]
    let segments: [TranscriptSegment]
    let kind: String

    init(_ artifact: TranscriptionArtifact) {
        meetingID = artifact.meetingID
        inputFingerprint = artifact.inputFingerprint
        sourceTranscriptRevision = artifact.sourceTranscriptRevision
        language = artifact.language
        speakers = artifact.speakers
        segments = artifact.segments
        kind = "transcription"
    }

    init(_ artifact: DiarizationArtifact) {
        meetingID = artifact.meetingID
        inputFingerprint = artifact.inputFingerprint
        sourceTranscriptRevision = artifact.sourceTranscriptRevision
        language = artifact.language
        speakers = artifact.speakers
        segments = artifact.segments
        kind = "diarization"
    }
}

extension MeetingStore {
    static func validateTranscriptArtifact(
        _ artifact: TranscriptArtifactEnvelope
    ) throws {
        let speakerIDs = Set(artifact.speakers.map(\.id))
        let segmentIDs = Set(artifact.segments.map(\.id))
        guard isCanonical(artifact.inputFingerprint),
            artifact.sourceTranscriptRevision >= 0,
            artifact.language.map(isCanonical) ?? true,
            !artifact.segments.isEmpty,
            speakerIDs.count == artifact.speakers.count,
            segmentIDs.count == artifact.segments.count,
            artifact.speakers.allSatisfy({ speaker in
                speaker.meetingID == artifact.meetingID && isCanonical(speaker.label)
            }),
            artifact.segments.allSatisfy({ segment in
                segment.meetingID == artifact.meetingID
                    && (segment.speakerID.map(speakerIDs.contains) ?? true)
                    && hasTranscriptContent(segment.text)
                    && segment.startTime.isFinite
                    && segment.endTime.isFinite
                    && segment.startTime >= 0
                    && segment.endTime >= segment.startTime
                    && (segment.confidence.map {
                        $0.isFinite && (0...1).contains($0)
                    } ?? true)
            })
        else {
            throw StorageError.invalidProcessingJob(
                "\(artifact.kind) artifact must be canonical, unique, and meeting-owned")
        }
    }

    static func requireTranscriptIdentities(
        _ artifact: TranscriptArtifactEnvelope,
        in db: Database
    ) throws {
        let meetingKey = artifact.meetingID.rawValue.uuidString
        for speaker in artifact.speakers {
            if let existing = try SpeakerRecord.fetchOne(
                db, key: speaker.id.rawValue.uuidString),
                existing.meetingID != meetingKey {
                throw StorageError.invalidProcessingJob(
                    "transcript cannot move an existing speaker between meetings")
            }
        }
        for segment in artifact.segments {
            if let existing = try SegmentRecord.fetchOne(db, key: segment.id.uuidString),
                existing.meetingID != meetingKey {
                throw StorageError.invalidProcessingJob(
                    "transcript cannot move an existing segment between meetings")
            }
        }
    }

    static func writeTranscriptArtifact(
        _ artifact: TranscriptArtifactEnvelope,
        meeting: inout MeetingRecord,
        at timestamp: Date,
        in db: Database
    ) throws {
        let key = artifact.meetingID.rawValue.uuidString
        try db.execute(
            sql: "UPDATE segment SET deletedAt = ?, updatedAt = ? "
                + "WHERE meetingID = ? AND deletedAt IS NULL",
            arguments: [timestamp, timestamp, key])
        try db.execute(
            sql: "UPDATE speaker SET deletedAt = ?, updatedAt = ? "
                + "WHERE meetingID = ? AND deletedAt IS NULL",
            arguments: [timestamp, timestamp, key])
        for speaker in artifact.speakers {
            let record = SpeakerRecord(
                speaker, createdAt: timestamp, updatedAt: timestamp)
            try record.save(db)
        }
        for segment in artifact.segments {
            let record = SegmentRecord(
                segment, createdAt: timestamp, updatedAt: timestamp)
            try record.save(db)
        }
        meeting.language = artifact.language
        meeting.transcriptRevision += 1
        meeting.updatedAt = timestamp
        try meeting.update(db)
    }

    private static func hasTranscriptContent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
