import DiarizationKit
import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit
import TranscriptionKit

/// Storage boundary for owner-leased post-capture work. Artifact publication
/// remains atomic in StorageKit; this workflow owns ordering and policy.
public protocol PostCaptureProcessingStore: Sendable {
    func claimPostCaptureJob(
        kinds: Set<ProcessingJobKind>,
        owner: String,
        leaseDuration: TimeInterval,
        at timestamp: Date
    ) async throws -> ProcessingJob?
    func heartbeatPostCaptureJob(
        _ id: ProcessingJobID,
        owner: String,
        progress: Double,
        leaseDuration: TimeInterval,
        at timestamp: Date
    ) async throws
    func suspendPostCaptureJob(
        _ id: ProcessingJobID,
        owner: String,
        at timestamp: Date
    ) async throws
    func postCaptureDetail(_ meetingID: MeetingID) async throws -> MeetingDetail?
    func postCaptureAudioAssets(_ meetingID: MeetingID) async throws -> [AudioAsset]
    func postCaptureContextItems(_ meetingID: MeetingID) async throws -> [ContextItem]
    func publishPostCaptureTranscription(
        _ jobID: ProcessingJobID,
        owner: String,
        artifact: TranscriptionArtifact,
        followUps: [ProcessingJobRequest],
        at timestamp: Date
    ) async throws -> ProcessingArtifactCommit
    func publishPostCaptureDiarization(
        _ jobID: ProcessingJobID,
        owner: String,
        artifact: DiarizationArtifact,
        followUps: [ProcessingJobRequest],
        at timestamp: Date
    ) async throws -> ProcessingArtifactCommit
    func publishPostCaptureSummary(
        _ jobID: ProcessingJobID,
        owner: String,
        artifact: SummaryArtifact,
        at timestamp: Date
    ) async throws
    func savePostCaptureGenerationRun(_ run: GenerationRun) async throws
    func failPostCaptureJob(
        _ jobID: ProcessingJobID,
        owner: String,
        failure: ProcessingJobFailure,
        retryAt: Date?,
        at timestamp: Date
    ) async throws
    func cancelPostCaptureJob(
        _ jobID: ProcessingJobID,
        owner: String,
        reason: ProcessingJobFailure,
        enqueue replacements: [ProcessingJobRequest],
        at timestamp: Date
    ) async throws -> ProcessingJobCancellation
    func nextPostCaptureProcessingDate(
        kinds: Set<ProcessingJobKind>,
        after timestamp: Date
    ) async throws -> Date?
}

public struct PostCaptureSummaryProviderSelection: Sendable {
    public let provider: any SummaryProvider
    public let providerID: String
    public let modelID: String
    public let modelRevision: String?

    public init(
        provider: any SummaryProvider,
        providerID: String,
        modelID: String,
        modelRevision: String?
    ) {
        self.provider = provider
        self.providerID = providerID
        self.modelID = modelID
        self.modelRevision = modelRevision
    }
}

public struct PostCaptureSummaryPreferences: Sendable {
    public let outputLanguage: String
    public let vocabulary: [String]

    public init(outputLanguage: String, vocabulary: [String]) {
        self.outputLanguage = outputLanguage
        self.vocabulary = vocabulary
    }
}

/// Concrete audio engines and files stay in executable composition. The
/// workflow receives only model results and explicit lifecycle effects.
public protocol PostCaptureAudioProcessing: Sendable {
    func transcribePostCaptureAudio(
        _ asset: AudioAsset,
        channel: AudioChannel,
        hints: TranscriptionHints
    ) async throws -> FileTranscription
    func currentPostCaptureVoiceprint() async -> Voiceprint?
    func diarizePostCaptureAudio(
        _ asset: AudioAsset,
        voiceprint: Voiceprint?
    ) async throws -> [SpeakerTurn]
    func schedulePostCaptureIdleRelease() async
}

/// Samples the currently configured summary provider and output preferences
/// without exposing persistence, model paths, or platform availability.
public protocol PostCaptureSummaryConfiguration: Sendable {
    func postCaptureSummaryProvider() async -> PostCaptureSummaryProviderSelection?
    func postCaptureSummaryPreferences(
        spokenLanguage: String?
    ) async -> PostCaptureSummaryPreferences
}

/// Best-effort external automation triggered only after the durable workflow's
/// exact completion conditions have been satisfied.
public protocol PostCaptureCompletionActions: Sendable {
    func runPostMeetingAction(for meetingID: MeetingID) async
}

public enum PostCaptureProcessingCapabilityError: Error, Equatable, LocalizedError, Sendable {
    case audioUnavailable

    public var errorDescription: String? {
        "The finalized capture audio is no longer available."
    }
}

public enum PostCaptureProcessingOutcome: String, Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
    case suspended
    case leaseLost
}

public enum PostCaptureProcessingIssueStage: Equatable, Sendable {
    case claim
    case failurePreservation(ProcessingJobKind)
}

public struct PostCaptureProcessingIssue: Equatable, Sendable {
    public let stage: PostCaptureProcessingIssueStage
    public let message: String

    public init(stage: PostCaptureProcessingIssueStage, message: String) {
        self.stage = stage
        self.message = message
    }
}

public enum PostCaptureProcessingEvent: Equatable, Sendable {
    case started(kind: ProcessingJobKind, attempt: Int)
    case finished(
        kind: ProcessingJobKind,
        attempt: Int,
        outcome: PostCaptureProcessingOutcome,
        durableStateChanged: Bool)
}

public typealias PostCaptureProcessingEventHandler =
    @Sendable (PostCaptureProcessingEvent) async -> Void

public struct ProcessPostCaptureJobsRequest: Sendable {
    public let owner: String
    public let progress: PostCaptureProcessingEventHandler

    public init(
        owner: String,
        progress: @escaping PostCaptureProcessingEventHandler = { _ in }
    ) {
        self.owner = owner
        self.progress = progress
    }
}

public struct ProcessPostCaptureJobsResult: Sendable {
    public let processedJobCount: Int
    public let durableStateChanged: Bool
    public let issues: [PostCaptureProcessingIssue]

    public init(
        processedJobCount: Int,
        durableStateChanged: Bool,
        issues: [PostCaptureProcessingIssue]
    ) {
        self.processedJobCount = processedJobCount
        self.durableStateChanged = durableStateChanged
        self.issues = issues
    }
}
