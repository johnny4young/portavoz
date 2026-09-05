import Foundation
import GRDB
import PortavozCore

struct CommitmentReminderStateRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "commitmentReminderState"

    var commitmentID: String
    var status: String
    var latestEventID: String
    var scheduledFor: Date?
    var sourceDueAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(_ state: CommitmentReminderState) {
        commitmentID = state.commitmentID.rawValue.uuidString
        status = state.status.rawValue
        latestEventID = state.latestEventID.rawValue.uuidString
        scheduledFor = state.scheduledFor
        sourceDueAt = state.sourceDueAt
        createdAt = state.createdAt
        updatedAt = state.updatedAt
    }

    var state: CommitmentReminderState {
        get throws {
            guard let status = CommitmentReminderStatus(rawValue: status) else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "status",
                    value: self.status)
            }
            return CommitmentReminderState(
                commitmentID: CommitmentID(rawValue: try PersistedIdentity.required(
                    commitmentID,
                    table: Self.databaseTableName,
                    column: "commitmentID")),
                status: status,
                latestEventID: CommitmentReminderEventID(
                    rawValue: try PersistedIdentity.required(
                        latestEventID,
                        table: Self.databaseTableName,
                        column: "latestEventID")),
                scheduledFor: scheduledFor,
                sourceDueAt: sourceDueAt,
                createdAt: createdAt,
                updatedAt: updatedAt)
        }
    }
}

struct CommitmentReminderEventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "commitmentReminderEvent"

    var id: String
    var commitmentID: String
    var previousEventID: String?
    var kind: String
    var scheduledFor: Date?
    var sourceDueAt: Date?
    var occurredAt: Date

    init(_ event: CommitmentReminderEvent) {
        id = event.id.rawValue.uuidString
        commitmentID = event.commitmentID.rawValue.uuidString
        previousEventID = event.previousEventID?.rawValue.uuidString
        kind = event.kind.rawValue
        scheduledFor = event.scheduledFor
        sourceDueAt = event.sourceDueAt
        occurredAt = event.occurredAt
    }

    var event: CommitmentReminderEvent {
        get throws {
            guard let kind = CommitmentReminderEventKind(rawValue: kind) else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "kind",
                    value: self.kind)
            }
            return CommitmentReminderEvent(
                id: CommitmentReminderEventID(rawValue: try PersistedIdentity.required(
                    id,
                    table: Self.databaseTableName,
                    column: "id")),
                commitmentID: CommitmentID(
                    rawValue: try PersistedIdentity.required(
                        commitmentID,
                        table: Self.databaseTableName,
                        column: "commitmentID")),
                previousEventID: try PersistedIdentity.optional(
                    previousEventID,
                    table: Self.databaseTableName,
                    column: "previousEventID"
                ).map(CommitmentReminderEventID.init(rawValue:)),
                kind: kind,
                scheduledFor: scheduledFor,
                sourceDueAt: sourceDueAt,
                occurredAt: occurredAt)
        }
    }
}
