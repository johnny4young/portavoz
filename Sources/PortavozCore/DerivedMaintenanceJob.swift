import Foundation

public struct DerivedMaintenanceJobID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum DerivedMaintenanceKind: String, CaseIterable, Codable, Sendable {
    case semanticCorpus = "semantic-corpus"
}

public enum DerivedMaintenanceJobState: String, Codable, Sendable {
    case pending
    case running
    case succeeded
    case failed
    case cancelled
}

/// Content-free durable ownership for degradable derived work.
///
/// `sourceGeneration` identifies the authoritative mutation set that admitted
/// the operation; it is not a work cursor. Each derived adapter keeps its own
/// replayable storage cursor, such as NULL semantic vectors.
public struct DerivedMaintenanceJob: Sendable {
    public let id: DerivedMaintenanceJobID
    public let kind: DerivedMaintenanceKind
    public let targetFingerprint: String
    public let sourceGeneration: Int
    public let operationFingerprint: String
    public let state: DerivedMaintenanceJobState
    public let attempt: Int
    public let maxAttempts: Int
    public let notBefore: Date?
    public let leaseOwner: String?
    public let leaseExpiresAt: Date?
    public let errorCode: String?
    public let createdAt: Date
    public let startedAt: Date?
    public let finishedAt: Date?
    public let updatedAt: Date

    public init(
        id: DerivedMaintenanceJobID = .init(),
        kind: DerivedMaintenanceKind,
        targetFingerprint: String,
        sourceGeneration: Int,
        operationFingerprint: String,
        state: DerivedMaintenanceJobState = .pending,
        attempt: Int = 0,
        maxAttempts: Int = 3,
        notBefore: Date? = nil,
        leaseOwner: String? = nil,
        leaseExpiresAt: Date? = nil,
        errorCode: String? = nil,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.targetFingerprint = targetFingerprint
        self.sourceGeneration = sourceGeneration
        self.operationFingerprint = operationFingerprint
        self.state = state
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.notBefore = notBefore
        self.leaseOwner = leaseOwner
        self.leaseExpiresAt = leaseExpiresAt
        self.errorCode = errorCode
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.updatedAt = updatedAt
    }
}

public enum SemanticCorpusMaintenanceFingerprint {
    public static func compute(
        targetFingerprint: String,
        sourceGeneration: Int
    ) -> String? {
        guard sourceGeneration >= 0,
              targetFingerprint.count == 64,
              targetFingerprint.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return OperationFingerprint.make(
            version: "semantic-corpus-maintenance-v1",
            components: [targetFingerprint.lowercased(), String(sourceGeneration)])
    }
}
