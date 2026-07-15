import Foundation
import GRDB
import PortavozCore

struct ProcessingJobRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "processingJob"

    var id: String
    var meetingID: String
    var kind: String
    var inputFingerprint: String
    var state: String
    var priority: Int
    var progress: Double
    var attempt: Int
    var maxAttempts: Int
    var notBefore: Date?
    var leaseOwner: String?
    var leaseExpiresAt: Date?
    var errorCode: String?
    var errorMessage: String?
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var updatedAt: Date

    init(_ job: ProcessingJob) {
        id = job.id.rawValue.uuidString
        meetingID = job.meetingID.rawValue.uuidString
        kind = job.kind.rawValue
        inputFingerprint = job.inputFingerprint
        state = job.state.rawValue
        priority = job.priority
        progress = job.progress
        attempt = job.attempt
        maxAttempts = job.maxAttempts
        notBefore = job.notBefore
        leaseOwner = job.leaseOwner
        leaseExpiresAt = job.leaseExpiresAt
        errorCode = job.errorCode
        errorMessage = job.errorMessage
        createdAt = job.createdAt
        startedAt = job.startedAt
        finishedAt = job.finishedAt
        updatedAt = job.updatedAt
    }

    var job: ProcessingJob {
        get throws {
            guard let jobState = ProcessingJobState(rawValue: state) else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName, column: "state", value: state)
            }
            try validatePersistedContract(state: jobState)
            return ProcessingJob(
                id: ProcessingJobID(rawValue: try PersistedIdentity.required(
                    id, table: Self.databaseTableName, column: "id")),
                meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                    meetingID, table: Self.databaseTableName, column: "meetingID")),
                kind: ProcessingJobKind(rawValue: kind),
                inputFingerprint: inputFingerprint,
                state: jobState,
                priority: priority,
                progress: progress,
                attempt: attempt,
                maxAttempts: maxAttempts,
                notBefore: notBefore,
                leaseOwner: leaseOwner,
                leaseExpiresAt: leaseExpiresAt,
                errorCode: errorCode,
                errorMessage: errorMessage,
                createdAt: createdAt,
                startedAt: startedAt,
                finishedAt: finishedAt,
                updatedAt: updatedAt)
        }
    }

    private func validatePersistedContract(state: ProcessingJobState) throws {
        guard isCanonical(kind), isCanonical(inputFingerprint),
            progress.isFinite, (0...1).contains(progress),
            attempt >= 0, maxAttempts > 0, attempt <= maxAttempts,
            isCanonicalOptional(errorCode),
            errorMessage == nil || errorCode != nil
        else { throw invalidContract(state) }

        let hasLease = isCanonicalOptional(leaseOwner) && leaseOwner != nil
            && leaseExpiresAt != nil
        switch state {
        case .pending:
            guard leaseOwner == nil, leaseExpiresAt == nil, finishedAt == nil else {
                throw invalidContract(state)
            }
        case .running:
            guard hasLease, attempt > 0, notBefore == nil, finishedAt == nil else {
                throw invalidContract(state)
            }
        case .succeeded:
            guard leaseOwner == nil, leaseExpiresAt == nil, notBefore == nil,
                finishedAt != nil, progress == 1, errorCode == nil, errorMessage == nil
            else { throw invalidContract(state) }
        case .failed, .cancelled:
            guard leaseOwner == nil, leaseExpiresAt == nil, notBefore == nil,
                finishedAt != nil
            else { throw invalidContract(state) }
        }
    }

    private func isCanonical(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isCanonicalOptional(_ value: String?) -> Bool {
        value.map(isCanonical) ?? true
    }

    private func invalidContract(_ state: ProcessingJobState) -> StorageError {
        StorageError.invalidPersistedValue(
            table: Self.databaseTableName,
            column: "stateContract",
            value: "\(state.rawValue):\(id)")
    }
}
