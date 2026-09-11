import Foundation
import GRDB
import PortavozCore

struct DerivedMaintenanceJobRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "derivedMaintenanceJob"

    var id: String
    var kind: String
    var targetFingerprint: String
    var sourceGeneration: Int
    var operationFingerprint: String
    var state: String
    var attempt: Int
    var maxAttempts: Int
    var notBefore: Date?
    var leaseOwner: String?
    var leaseExpiresAt: Date?
    var errorCode: String?
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var updatedAt: Date

    init(_ job: DerivedMaintenanceJob) {
        id = job.id.rawValue.uuidString
        kind = job.kind.rawValue
        targetFingerprint = job.targetFingerprint
        sourceGeneration = job.sourceGeneration
        operationFingerprint = job.operationFingerprint
        state = job.state.rawValue
        attempt = job.attempt
        maxAttempts = job.maxAttempts
        notBefore = job.notBefore
        leaseOwner = job.leaseOwner
        leaseExpiresAt = job.leaseExpiresAt
        errorCode = job.errorCode
        createdAt = job.createdAt
        startedAt = job.startedAt
        finishedAt = job.finishedAt
        updatedAt = job.updatedAt
    }

    var job: DerivedMaintenanceJob {
        get throws {
            guard let kind = DerivedMaintenanceKind(rawValue: kind),
                  let state = DerivedMaintenanceJobState(rawValue: state)
            else { throw invalidContract() }
            try validate(state: state)
            return DerivedMaintenanceJob(
                id: DerivedMaintenanceJobID(rawValue: try PersistedIdentity.required(
                    id, table: Self.databaseTableName, column: "id")),
                kind: kind,
                targetFingerprint: targetFingerprint,
                sourceGeneration: sourceGeneration,
                operationFingerprint: operationFingerprint,
                state: state,
                attempt: attempt,
                maxAttempts: maxAttempts,
                notBefore: notBefore,
                leaseOwner: leaseOwner,
                leaseExpiresAt: leaseExpiresAt,
                errorCode: errorCode,
                createdAt: createdAt,
                startedAt: startedAt,
                finishedAt: finishedAt,
                updatedAt: updatedAt)
        }
    }

    private func validate(state: DerivedMaintenanceJobState) throws {
        guard targetFingerprint.count == 64,
              targetFingerprint.allSatisfy({ $0.isHexDigit }),
              sourceGeneration >= 0,
              operationFingerprint.count == 64,
              operationFingerprint.allSatisfy({ $0.isHexDigit }),
              attempt >= 0,
              maxAttempts > 0,
              attempt <= maxAttempts,
              isCanonicalOptional(errorCode)
        else { throw invalidContract() }

        let ownsLease = leaseOwner.map(isCanonical) == true
            && leaseExpiresAt != nil
        switch state {
        case .pending:
            guard leaseOwner == nil, leaseExpiresAt == nil, finishedAt == nil else {
                throw invalidContract()
            }
        case .running:
            guard ownsLease, attempt > 0, notBefore == nil, finishedAt == nil else {
                throw invalidContract()
            }
        case .succeeded:
            guard leaseOwner == nil, leaseExpiresAt == nil, notBefore == nil,
                  finishedAt != nil, errorCode == nil
            else { throw invalidContract() }
        case .failed:
            guard leaseOwner == nil, leaseExpiresAt == nil, notBefore == nil,
                  finishedAt != nil, errorCode != nil
            else { throw invalidContract() }
        case .cancelled:
            guard leaseOwner == nil, leaseExpiresAt == nil, notBefore == nil,
                  finishedAt != nil
            else { throw invalidContract() }
        }
    }

    private func isCanonical(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == value && !trimmed.isEmpty && trimmed.count <= 256
    }

    private func isCanonicalOptional(_ value: String?) -> Bool {
        value.map(isCanonical) ?? true
    }

    private func invalidContract() -> StorageError {
        .invalidDerivedMaintenanceJob(
            "persisted derived maintenance state is malformed")
    }
}
