import CloudKit
import Foundation

public struct CloudSyncClassifiedFailure: Equatable, Sendable {
    public let category: CloudSyncFailureCategory
    public let retryAfter: TimeInterval?

    public init(category: CloudSyncFailureCategory, retryAfter: TimeInterval?) {
        self.category = category
        self.retryAfter = retryAfter
    }
}

public enum CloudSyncFailureClassifier {
    public static func classify(_ error: Error) -> CloudSyncClassifiedFailure {
        let error = error as NSError
        guard error.domain == CKError.errorDomain,
              let code = CKError.Code(rawValue: error.code)
        else {
            return CloudSyncClassifiedFailure(category: .terminal, retryAfter: nil)
        }
        if code == .serverRecordChanged {
            return CloudSyncClassifiedFailure(category: .serverConflict, retryAfter: nil)
        }
        let transientCodes: Set<CKError.Code> = [
            .networkUnavailable,
            .networkFailure,
            .serviceUnavailable,
            .requestRateLimited,
            .zoneBusy,
            .serverResponseLost,
            .partialFailure
        ]
        let category: CloudSyncFailureCategory = transientCodes.contains(code)
            ? .transient
            : .terminal
        return CloudSyncClassifiedFailure(
            category: category,
            retryAfter: (error as? CKError)?.retryAfterSeconds
                ?? error.userInfo[CKErrorRetryAfterKey] as? TimeInterval)
    }

    public static func serverRecord(from error: Error) -> CKRecord? {
        let error = error as NSError
        return (error as? CKError)?.serverRecord
            ?? error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
    }
}
