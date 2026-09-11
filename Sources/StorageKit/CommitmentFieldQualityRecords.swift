import Foundation
import GRDB
import PortavozCore

struct CommitmentFieldPresentationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "commitmentFieldPresentation"

    var id: String
    var actionItemID: String
    var language: String
    var suggestedOwnerToken: String?
    var suggestedDueAt: Date?
    var firstPresentedAt: Date
}

struct CommitmentFieldQualityObservationRow: Decodable, FetchableRecord {
    var id: String
    var language: String
    var firstPresentedAt: Date
    var outcome: String
    var reviewedAt: Date?
    var suggestedOwnerToken: String?
    var confirmedAssigneeKind: String?
    var confirmedPersonID: String?
    var suggestedDueAt: Date?
    var confirmedDueAt: Date?

    var observation: CommitmentFieldQualityObservation {
        get throws {
            guard let language = CommitmentFieldQualityLanguage(rawValue: language),
                  let outcome = CommitmentFieldQualityOutcome(rawValue: outcome)
            else {
                throw StorageError.invalidCommitment(
                    "field-quality observation contains an unsupported state")
            }
            switch outcome {
            case .confirmed:
                guard reviewedAt != nil, confirmedAssigneeKind != nil else {
                    throw StorageError.invalidCommitment(
                        "confirmed field observation lacks its first confirmation event")
                }
            case .dismissed:
                guard reviewedAt != nil,
                      confirmedAssigneeKind == nil,
                      confirmedPersonID == nil,
                      confirmedDueAt == nil
                else {
                    throw StorageError.invalidCommitment(
                        "dismissed field observation has invalid terminal material")
                }
            case .pending, .deferred, .withdrawn:
                guard reviewedAt == nil,
                      confirmedAssigneeKind == nil,
                      confirmedPersonID == nil,
                      confirmedDueAt == nil
                else {
                    throw StorageError.invalidCommitment(
                        "nonterminal field observation has terminal material")
                }
            }
            return CommitmentFieldQualityObservation(
                id: try PersistedIdentity.required(
                    id,
                    table: CommitmentFieldPresentationRecord.databaseTableName,
                    column: "id"),
                language: language,
                firstPresentedAt: firstPresentedAt,
                outcome: outcome,
                reviewedAt: reviewedAt,
                suggestedOwnerToken: try PersistedIdentity.optional(
                    suggestedOwnerToken,
                    table: CommitmentFieldPresentationRecord.databaseTableName,
                    column: "suggestedOwnerToken"),
                confirmedOwnerToken: try confirmedOwnerToken,
                suggestedDueAt: suggestedDueAt,
                confirmedDueAt: confirmedDueAt,
                confirmationBasis: outcome == .confirmed
                    ? .generatedDirectEvidence
                    : nil)
        }
    }

    private var confirmedOwnerToken: UUID? {
        get throws {
            guard let confirmedAssigneeKind else { return nil }
            guard let kind = CommitmentAssigneeKind(rawValue: confirmedAssigneeKind),
                  let assignee = CommitmentAssignee(
                      kind: kind,
                      canonicalPersonID: try PersistedIdentity.optional(
                          confirmedPersonID,
                          table: CommitmentEventRecord.databaseTableName,
                          column: "canonicalPersonID"
                      ).map { PersonID(rawValue: $0) })
            else {
                throw StorageError.invalidCommitment(
                    "field-quality confirmation contains an invalid assignee")
            }
            return CommitmentFieldOwnerToken.token(for: assignee)
        }
    }
}
