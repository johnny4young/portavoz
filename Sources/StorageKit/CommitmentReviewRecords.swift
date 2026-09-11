import Foundation
import GRDB
import PortavozCore

struct CommitmentReviewDecisionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "commitmentReviewDecision"

    var actionItemID: String
    var disposition: String
    var revisitAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        _ decision: CommitmentReviewDecision,
        createdAt: Date,
        deletedAt: Date? = nil
    ) {
        actionItemID = decision.actionItemID.uuidString
        disposition = decision.disposition.rawValue
        revisitAt = decision.revisitAt
        self.createdAt = createdAt
        updatedAt = decision.updatedAt
        self.deletedAt = deletedAt
    }

    var decision: CommitmentReviewDecision {
        get throws {
            let actionItemID = try PersistedIdentity.required(
                actionItemID,
                table: Self.databaseTableName,
                column: "actionItemID")
            guard let disposition = CommitmentReviewDisposition(rawValue: disposition) else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "disposition",
                    value: self.disposition)
            }
            let decision = CommitmentReviewDecision(
                actionItemID: actionItemID,
                disposition: disposition,
                revisitAt: revisitAt,
                updatedAt: updatedAt)
            do {
                try CommitmentReviewPolicy.validate(decision)
                return decision
            } catch {
                throw StorageError.invalidCommitment(
                    "persisted review decision failed validation: \(error)")
            }
        }
    }
}
