import Foundation
import PortavozCore
import StorageKit

extension MeetingStore: PostCaptureProcessingStore {
    public func claimPostCaptureJob(
        kinds: Set<ProcessingJobKind>,
        owner: String,
        leaseDuration: TimeInterval,
        at timestamp: Date
    ) async throws -> ProcessingJob? {
        try await claimNextProcessingJob(
            kinds: kinds,
            owner: owner,
            leaseDuration: leaseDuration,
            at: timestamp)
    }

    public func heartbeatPostCaptureJob(
        _ id: ProcessingJobID,
        owner: String,
        progress: Double,
        leaseDuration: TimeInterval,
        at timestamp: Date
    ) async throws {
        _ = try await heartbeatProcessingJob(
            id,
            owner: owner,
            progress: progress,
            leaseDuration: leaseDuration,
            at: timestamp)
    }

    public func postCaptureDetail(_ meetingID: MeetingID) async throws -> MeetingDetail? {
        try await detail(meetingID)
    }

    public func postCaptureAudioAssets(_ meetingID: MeetingID) async throws -> [AudioAsset] {
        try await audioAssets(for: meetingID)
    }

    public func postCaptureContextItems(_ meetingID: MeetingID) async throws -> [ContextItem] {
        try await contextItems(for: meetingID)
    }

    public func publishPostCaptureTranscription(
        _ jobID: ProcessingJobID,
        owner: String,
        artifact: TranscriptionArtifact,
        followUps: [ProcessingJobRequest],
        at timestamp: Date
    ) async throws -> ProcessingArtifactCommit {
        try await completeTranscriptionJob(
            jobID,
            owner: owner,
            artifact: artifact,
            enqueue: followUps,
            at: timestamp)
    }

    public func publishPostCaptureDiarization(
        _ jobID: ProcessingJobID,
        owner: String,
        artifact: DiarizationArtifact,
        followUps: [ProcessingJobRequest],
        at timestamp: Date
    ) async throws -> ProcessingArtifactCommit {
        try await completeDiarizationJob(
            jobID,
            owner: owner,
            artifact: artifact,
            enqueue: followUps,
            at: timestamp)
    }

    public func publishPostCaptureSummary(
        _ jobID: ProcessingJobID,
        owner: String,
        artifact: SummaryArtifact,
        at timestamp: Date
    ) async throws {
        _ = try await completeSummaryJob(
            jobID,
            owner: owner,
            artifact: artifact,
            at: timestamp)
    }

    public func savePostCaptureGenerationRun(_ run: GenerationRun) async throws {
        try await saveGenerationRun(run)
    }

    public func failPostCaptureJob(
        _ jobID: ProcessingJobID,
        owner: String,
        failure: ProcessingJobFailure,
        retryAt: Date?,
        at timestamp: Date
    ) async throws {
        _ = try await failProcessingJob(
            jobID,
            owner: owner,
            failure: failure,
            retryAt: retryAt,
            at: timestamp)
    }

    public func cancelPostCaptureJob(
        _ jobID: ProcessingJobID,
        owner: String,
        reason: ProcessingJobFailure,
        at timestamp: Date
    ) async throws {
        _ = try await cancelProcessingJob(
            jobID,
            owner: owner,
            reason: reason,
            at: timestamp)
    }

    public func nextPostCaptureProcessingDate(
        kinds: Set<ProcessingJobKind>,
        after timestamp: Date
    ) async throws -> Date? {
        try await nextScheduledProcessingDate(kinds: kinds, after: timestamp)
    }
}
