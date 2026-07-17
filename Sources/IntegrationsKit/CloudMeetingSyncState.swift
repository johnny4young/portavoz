import Foundation
import PortavozCore

public enum CloudMeetingTransportError: Error, Equatable, Sendable {
    case invalidState(String)
    case consentRequired
    case accountUnavailable
    case staleGeneration
    case generationCollision
    case unknownAttempt
    case payloadMissing
    case payloadCorrupted
}

public enum CloudSyncAccountStatus: String, Codable, Equatable, Sendable {
    case unknown
    case available
    case signedOut
    case restricted
    case temporarilyUnavailable
}

public enum CloudSyncAttemptPhase: String, Codable, Equatable, Sendable {
    case ready
    case retryWaiting
    case blocked
}

public enum CloudSyncFailureCategory: String, Codable, Equatable, Sendable {
    case transient
    case serverConflict
    case terminal
}

public enum CloudSyncInitialSeedState: Equatable, Sendable {
    case blocked
    case notRequested
    case requested
    case complete
}

public enum CloudSyncReplayDecision: Equatable, Sendable {
    case apply
    case ignoreOwnDevice
    case ignoreDuplicate
    case ignoreStale
}

public struct CloudSyncFailureResolution: Equatable, Sendable {
    public let category: CloudSyncFailureCategory
    public let shouldRetry: Bool

    public init(category: CloudSyncFailureCategory, shouldRetry: Bool) {
        self.category = category
        self.shouldRetry = shouldRetry
    }
}

public struct CloudSyncAttempt: Codable, Equatable, Sendable {
    public let meetingID: MeetingID
    public let sourceDeviceID: UUID
    public let generation: Int
    public let changedAt: Date
    public let payloadFileName: String
    public let payloadSHA256: String
    public let payloadByteCount: Int
    public var phase: CloudSyncAttemptPhase
    public var attemptCount: Int
    public var nextRetryAt: Date?
    public var lastFailure: CloudSyncFailureCategory?
}

public struct CloudSyncReplayCursor: Codable, Equatable, Sendable {
    public let meetingID: MeetingID
    public let sourceDeviceID: UUID
    public let generation: Int
    public let payloadSHA256: String
}

public struct CloudSyncRecordMetadata: Codable, Equatable, Sendable {
    public let meetingID: MeetingID
    public let systemFields: Data
}

/// A fetched live envelope that StorageKit deliberately deferred behind an
/// unsent local generation. The protected payload survives CKSyncEngine's
/// fetch checkpoint and is discarded only when a later local save supersedes
/// it or account-scoped state is reset.
public struct CloudSyncDeferredReplay: Codable, Equatable, Sendable {
    public let meetingID: MeetingID
    public let sourceDeviceID: UUID
    public let generation: Int
    public let changedAt: Date
    public let payloadFileName: String
    public let payloadSHA256: String
    public let payloadByteCount: Int
}

public struct CloudMeetingSyncSnapshot: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion = Self.currentFormatVersion
    public var accountStatus: CloudSyncAccountStatus = .unknown
    public var currentAccountFingerprint: String?
    public var accountScopeFingerprint: String?
    public var consentedAccountFingerprint: String?
    public var consentGrantedAt: Date?
    public var initialSeedRequestedAt: Date?
    public var initialSeedCompletedAt: Date?
    public var initialSeedAccountFingerprint: String?
    public var engineStateData: Data?
    public var attempts: [CloudSyncAttempt] = []
    public var deferredReplays: [CloudSyncDeferredReplay] = []
    public var replayCursors: [CloudSyncReplayCursor] = []
    public var recordMetadata: [CloudSyncRecordMetadata] = []

    public init() {}

    public var isTransportReady: Bool {
        accountStatus == .available
            && currentAccountFingerprint != nil
            && currentAccountFingerprint == consentedAccountFingerprint
    }

    public var initialSeedState: CloudSyncInitialSeedState {
        guard isTransportReady else { return .blocked }
        guard initialSeedAccountFingerprint == currentAccountFingerprint else {
            return .notRequested
        }
        if initialSeedCompletedAt != nil {
            return .complete
        }
        return initialSeedRequestedAt == nil ? .notRequested : .requested
    }
}

public struct CloudSyncRetryPolicy: Equatable, Sendable {
    public let baseDelay: TimeInterval
    public let maximumDelay: TimeInterval

    public init(baseDelay: TimeInterval = 5, maximumDelay: TimeInterval = 21_600) {
        precondition(baseDelay > 0 && maximumDelay >= baseDelay)
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
    }

    public func delay(afterAttempt attempt: Int, serverRetryAfter: TimeInterval?) -> TimeInterval {
        let exponent = max(0, min(attempt - 1, 20))
        let exponential = baseDelay * pow(2, Double(exponent))
        return min(max(exponential, serverRetryAfter ?? 0), maximumDelay)
    }
}
