import Foundation

/// Extensible work kind. Persisted values stay open so adding a local worker
/// does not require a schema migration.
public struct ProcessingJobKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let transcription = ProcessingJobKind(rawValue: "transcription")
    public static let refine = ProcessingJobKind(rawValue: "refine")
    public static let diarization = ProcessingJobKind(rawValue: "diarization")
    public static let summary = ProcessingJobKind(rawValue: "summary")
    public static let index = ProcessingJobKind(rawValue: "index")
}

public enum ProcessingJobState: String, Codable, CaseIterable, Sendable {
    case pending
    case running
    case succeeded
    case failed
    case cancelled
}

/// Stable idempotency and execution policy for one derived operation.
public struct ProcessingJobRequest: Sendable, Equatable {
    public let kind: ProcessingJobKind
    public let inputFingerprint: String
    public let priority: Int
    public let maxAttempts: Int
    public let notBefore: Date?

    public init(
        kind: ProcessingJobKind,
        inputFingerprint: String,
        priority: Int = 0,
        maxAttempts: Int = 3,
        notBefore: Date? = nil
    ) {
        self.kind = kind
        self.inputFingerprint = inputFingerprint
        self.priority = priority
        self.maxAttempts = maxAttempts
        self.notBefore = notBefore
    }
}

public struct ProcessingJobFailure: Sendable, Equatable {
    public let code: String
    public let message: String?

    public init(code: String, message: String? = nil) {
        self.code = code
        self.message = message
    }
}

/// A complete first-pass transcript recovered from finalized capture audio.
/// The artifact is fenced to the exact audio/model fingerprint and source
/// transcript revision owned by its durable job. Storage publishes the cast,
/// advances the revision, and admits dependent diarization atomically.
public struct TranscriptionArtifact: Sendable {
    public let meetingID: MeetingID
    public let inputFingerprint: String
    public let sourceTranscriptRevision: Int
    public let language: String?
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]

    public init(
        meetingID: MeetingID,
        inputFingerprint: String,
        sourceTranscriptRevision: Int,
        language: String?,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) {
        self.meetingID = meetingID
        self.inputFingerprint = inputFingerprint
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.language = language
        self.speakers = speakers
        self.segments = segments
    }
}

/// A diarization result tied to the exact transcript state that produced it.
/// `inputFingerprint` is the durable operation identity, not a display or
/// cache key; StorageKit rejects a result if either it or the source revision
/// no longer matches the owned job.
public struct DiarizationArtifact: Sendable {
    public let meetingID: MeetingID
    public let inputFingerprint: String
    public let sourceTranscriptRevision: Int
    public let language: String?
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]

    public init(
        meetingID: MeetingID,
        inputFingerprint: String,
        sourceTranscriptRevision: Int,
        language: String?,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) {
        self.meetingID = meetingID
        self.inputFingerprint = inputFingerprint
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.language = language
        self.speakers = speakers
        self.segments = segments
    }
}

/// An immutable summary result tied to the transcript revision and full
/// operation fingerprint claimed by its worker. `draft.fingerprint` keeps its
/// existing material-cache semantics and is deliberately separate because it
/// excludes output language (D25). `generationRun` is the successful model
/// attempt that must cross the same durable publication fence (D63).
public struct SummaryArtifact: Sendable {
    public let inputFingerprint: String
    public let sourceTranscriptRevision: Int
    public let draft: SummaryDraft
    public let generationRun: GenerationRun

    public init(
        inputFingerprint: String,
        sourceTranscriptRevision: Int,
        draft: SummaryDraft,
        generationRun: GenerationRun
    ) {
        self.inputFingerprint = inputFingerprint
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.draft = draft
        self.generationRun = generationRun
    }
}

/// Result of one atomic artifact publication. `artifactVersion` is the new
/// transcript revision for diarization and the immutable snapshot version for
/// summary generation.
public struct ProcessingArtifactCommit: Sendable {
    public let completedJob: ProcessingJob
    public let enqueuedJobs: [ProcessingJob]
    public let artifactVersion: Int

    public init(
        completedJob: ProcessingJob,
        enqueuedJobs: [ProcessingJob],
        artifactVersion: Int
    ) {
        self.completedJob = completedJob
        self.enqueuedJobs = enqueuedJobs
        self.artifactVersion = artifactVersion
    }
}

/// Durable job state. Workers mutate it only through an owner-bound lease;
/// callers use `(meetingID, kind, inputFingerprint)` as the idempotency key.
public struct ProcessingJob: Sendable, Identifiable, Equatable {
    public let id: ProcessingJobID
    public let meetingID: MeetingID
    public let kind: ProcessingJobKind
    public let inputFingerprint: String
    public let state: ProcessingJobState
    public let priority: Int
    public let progress: Double
    public let attempt: Int
    public let maxAttempts: Int
    public let notBefore: Date?
    public let leaseOwner: String?
    public let leaseExpiresAt: Date?
    public let errorCode: String?
    public let errorMessage: String?
    public let createdAt: Date
    public let startedAt: Date?
    public let finishedAt: Date?
    public let updatedAt: Date

    public init(
        id: ProcessingJobID = ProcessingJobID(),
        meetingID: MeetingID,
        kind: ProcessingJobKind,
        inputFingerprint: String,
        state: ProcessingJobState = .pending,
        priority: Int = 0,
        progress: Double = 0,
        attempt: Int = 0,
        maxAttempts: Int = 3,
        notBefore: Date? = nil,
        leaseOwner: String? = nil,
        leaseExpiresAt: Date? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.inputFingerprint = inputFingerprint
        self.state = state
        self.priority = priority
        self.progress = progress
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.notBefore = notBefore
        self.leaseOwner = leaseOwner
        self.leaseExpiresAt = leaseExpiresAt
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.updatedAt = updatedAt ?? createdAt
    }
}
