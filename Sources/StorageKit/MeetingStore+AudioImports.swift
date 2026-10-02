import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Each selected file and its required work become visible together. A
    /// repeated admission returns the original job, never a second import.
    public func enqueueAudioImports(
        _ inputs: [AudioImportRequest], at timestamp: Date = Date()
    ) async throws -> [ProcessingJob] {
        guard timestamp.timeIntervalSince1970.isFinite, !inputs.isEmpty, inputs.count <= 1_000,
              Set(inputs.map(\.meetingID)).count == inputs.count else {
            throw StorageError.invalidImportedMeeting("admission needs 1...1000 distinct files")
        }
        var budget = 16 * 1_048_576
        let encoded = try inputs.map { input in
            let record = try AudioImportInputRecord.admission(input)
            guard record.payload.count <= budget else {
                throw StorageError.invalidImportedMeeting("selection metadata exceeds 16 MiB")
            }
            budget -= record.payload.count
            return record
        }
        return try await database.write { db in
            try zip(inputs, encoded).map { input, record in
                if let existing = try AudioImportInputRecord.fetchOne(db, key: record.meetingID) {
                    guard existing.inputFingerprint == record.inputFingerprint,
                          let meeting = try MeetingRecord.fetchOne(db, key: record.meetingID),
                          meeting.deletedAt == nil,
                          let job = try ProcessingJobRecord.fetchOne(db, key: existing.jobID),
                          job.kind == ProcessingJobKind.audioImport.rawValue,
                          job.inputFingerprint == existing.inputFingerprint else {
                        throw StorageError.invalidImportedMeeting("admission identity is already occupied")
                    }
                    _ = try existing.decoded()
                    return try job.job
                }
                guard try MeetingRecord.fetchOne(db, key: record.meetingID) == nil else {
                    throw StorageError.invalidImportedMeeting("admission cannot replace an existing meeting")
                }
                let meeting = Meeting(
                    id: input.meetingID, title: input.title, startedAt: timestamp,
                    audioDirectory: input.copyDirectory,
                    lifecycleState: .processing)
                try MeetingRecord(meeting, createdAt: timestamp, updatedAt: timestamp).insert(db)
                let job = try Self.enqueueProcessingRequest(
                    ProcessingJobRequest(kind: .audioImport, inputFingerprint: record.inputFingerprint),
                    meetingID: input.meetingID, timestamp: timestamp, in: db)
                var installed = record
                installed.jobID = job.id.rawValue.uuidString
                try installed.insert(db)
                return job
            }
        }
    }

    /// Only the current lease may read a source capability for execution.
    public func audioImportInput(
        for jobID: ProcessingJobID, owner: String, at timestamp: Date = Date()
    ) async throws -> AudioImportRequest {
        try await database.read { db in
            try Self.ownedAudioImport(jobID, owner: owner, at: timestamp, in: db).input.decoded()
        }
    }

    /// Invalidates a running owner as well as queued work. A late worker can
    /// neither heartbeat nor publish under the cancelled lease.
    @discardableResult
    public func cancelAudioImport(
        for meetingID: MeetingID, at timestamp: Date = Date()
    ) async throws -> ProcessingJob {
        guard timestamp.timeIntervalSince1970.isFinite else {
            throw StorageError.invalidImportedMeeting("invalid import cancellation time")
        }
        return try await database.write { db in
            let key = meetingID.rawValue.uuidString
            guard let input = try AudioImportInputRecord.fetchOne(db, key: key),
                  let meeting = try MeetingRecord.fetchOne(db, key: key), meeting.deletedAt == nil,
                  var job = try ProcessingJobRecord.fetchOne(db, key: input.jobID),
                  job.kind == ProcessingJobKind.audioImport.rawValue,
                  job.inputFingerprint == input.inputFingerprint else {
                throw StorageError.meetingNotFound(meetingID)
            }
            guard job.state == ProcessingJobState.pending.rawValue
                || job.state == ProcessingJobState.running.rawValue else { return try job.job }
            job.state = ProcessingJobState.cancelled.rawValue
            job.leaseOwner = nil
            job.leaseExpiresAt = nil
            job.notBefore = nil
            job.errorCode = "import.cancelled"
            job.errorMessage = nil
            job.finishedAt = timestamp
            job.updatedAt = timestamp
            try job.update(db)
            try Self.reconcileProcessingLifecycle(for: meetingID, at: timestamp, in: db)
            return try job.job
        }
    }

    static func ownedAudioImport(
        _ jobID: ProcessingJobID, owner: String, at timestamp: Date, in db: Database
    ) throws -> (job: ProcessingJobRecord, meeting: MeetingRecord, input: AudioImportInputRecord) {
        guard timestamp.timeIntervalSince1970.isFinite else {
            throw StorageError.invalidImportedMeeting("invalid import ownership time")
        }
        let job = try ownedJob(jobID, owner: owner, at: timestamp, in: db)
        guard job.kind == ProcessingJobKind.audioImport.rawValue,
              let meeting = try MeetingRecord.fetchOne(db, key: job.meetingID), meeting.deletedAt == nil,
              let input = try AudioImportInputRecord.fetchOne(db, key: job.meetingID),
              input.jobID == job.id, input.inputFingerprint == job.inputFingerprint else {
            throw StorageError.invalidImportedMeeting("missing owned import input")
        }
        return (job, meeting, input)
    }

    /// Explicit user intent may restart failed or cancelled import work, but
    /// never replays successful insertion or steals a running owner's lease.
    @discardableResult
    public func retryAudioImport(
        for meetingID: MeetingID, at timestamp: Date = Date()
    ) async throws -> ProcessingJob {
        guard timestamp.timeIntervalSince1970.isFinite else {
            throw StorageError.invalidImportedMeeting("invalid import retry time")
        }
        return try await database.write { db in
            let key = meetingID.rawValue.uuidString
            guard let meeting = try MeetingRecord.fetchOne(db, key: key), meeting.deletedAt == nil,
                  let input = try AudioImportInputRecord.fetchOne(db, key: key),
                  var job = try ProcessingJobRecord.fetchOne(db, key: input.jobID),
                  job.kind == ProcessingJobKind.audioImport.rawValue,
                  job.inputFingerprint == input.inputFingerprint else {
                throw StorageError.invalidImportedMeeting("missing retryable import")
            }
            _ = try input.decoded()
            guard job.state == ProcessingJobState.failed.rawValue
                || job.state == ProcessingJobState.cancelled.rawValue else { return try job.job }
            job.resetForExplicitRetry(at: timestamp)
            try job.update(db)
            try Self.reconcileProcessingLifecycle(for: meetingID, at: timestamp, in: db)
            return try job.job
        }
    }
}
