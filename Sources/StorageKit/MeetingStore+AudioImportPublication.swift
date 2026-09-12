import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// The file adapter must finish and verify an immutable per-attempt copy
    /// before this transaction retires the external source capability.
    public func publishAudioImportCopy(
        for jobID: ProcessingJobID, owner: String,
        relativeDirectory: String, digest: String, at timestamp: Date = Date()
    ) async throws -> AudioImportRequest {
        try await database.write { db in
            var owned = try Self.ownedAudioImport(jobID, owner: owner, at: timestamp, in: db)
            var request = try owned.input.decoded()
            guard relativeDirectory == request.copyDirectory else {
                throw StorageError.invalidImportedMeeting("copy does not match its reserved stage")
            }
            if let existing = request.copiedAudioDirectory {
                guard existing == relativeDirectory, request.copiedAudioDigest == digest else {
                    throw StorageError.invalidImportedMeeting("owned copy cannot be replaced")
                }
                return request
            }
            guard owned.meeting.audioDirectory == request.copyDirectory else {
                throw StorageError.invalidImportedMeeting("import audio reservation changed")
            }
            request.sourceBookmark = nil
            request.copiedAudioDirectory = relativeDirectory
            request.copiedAudioDigest = digest
            try owned.input.replacePayload(request)
            try owned.input.update(db)
            owned.meeting.updatedAt = timestamp
            try owned.meeting.update(db)
            return request
        }
    }

    /// Required transcript and job success share one write transaction. The
    /// durable copy survives failed/cancelled processing and can be retried.
    public func completeAudioImport(
        _ jobID: ProcessingJobID, owner: String, artifact: TranscriptionArtifact,
        audioDuration: TimeInterval, audioDigest: String, at timestamp: Date = Date()
    ) async throws -> ProcessingArtifactCommit {
        let transcript = TranscriptArtifactEnvelope(artifact)
        // A genuinely silent selected file still belongs in the library.
        try Self.validateTranscriptArtifact(transcript, allowingEmptyTranscript: true)
        guard audioDuration.isFinite, audioDuration >= 0,
              timestamp.timeIntervalSince1970.isFinite else {
            throw StorageError.invalidImportedMeeting("invalid import completion time")
        }
        return try await database.write { db in
            var owned = try Self.ownedAudioImport(jobID, owner: owner, at: timestamp, in: db)
            let input = try owned.input.decoded()
            guard input.meetingID == artifact.meetingID,
                  owned.job.inputFingerprint == artifact.inputFingerprint,
                  artifact.sourceTranscriptRevision == 0, owned.meeting.transcriptRevision == 0,
                  input.sourceBookmark == nil, input.copiedAudioDigest == audioDigest,
                  let directory = input.copiedAudioDirectory, owned.meeting.audioDirectory == directory else {
                throw StorageError.invalidImportedMeeting("import result does not match its owned source")
            }
            let key = owned.meeting.id
            guard try SegmentRecord.filter(Column("meetingID") == key).fetchCount(db) == 0,
                  try SpeakerRecord.filter(Column("meetingID") == key).fetchCount(db) == 0 else {
                throw StorageError.invalidImportedMeeting("import cannot replace accepted content")
            }
            try Self.requireTranscriptIdentities(transcript, in: db)
            let end = owned.meeting.startedAt.addingTimeInterval(audioDuration)
            guard end.timeIntervalSince1970.isFinite else {
                throw StorageError.invalidImportedMeeting("invalid import end time")
            }
            owned.meeting.endedAt = end
            try Self.writeTranscriptArtifact(transcript, meeting: &owned.meeting, at: timestamp, in: db)
            let completed = try Self.succeed(&owned.job, at: timestamp, in: db)
            try Self.reconcileProcessingLifecycle(for: input.meetingID, at: timestamp, in: db)
            return ProcessingArtifactCommit(
                completedJob: completed, enqueuedJobs: [], artifactVersion: owned.meeting.transcriptRevision)
        }
    }
}
