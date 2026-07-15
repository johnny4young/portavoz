import Foundation

/// Extensible work kind. Persisted values stay open so adding a local worker
/// does not require a schema migration.
public struct ProcessingJobKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

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
