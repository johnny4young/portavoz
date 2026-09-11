import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Durably records "the user said no" for one offer identity. Idempotent:
    /// dismissing twice keeps the first timestamp.
    public func dismissSkillOffer(
        offerKey: String,
        skillID: String,
        at timestamp: Date = Date()
    ) async throws {
        guard !offerKey.isEmpty,
              offerKey.utf8.count <= SkillOfferRegistration.maximumOfferKeyByteCount,
              !skillID.isEmpty,
              skillID == skillID.trimmingCharacters(in: .whitespacesAndNewlines),
              skillID.utf8.count <= SkillDefinition.maximumIDByteCount,
              timestamp.timeIntervalSinceReferenceDate.isFinite
        else { throw StorageError.invalidSkillOffer("invalid dismissal") }
        try await database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO skillOfferDismissal (offerKey, skillID, dismissedAt)
                    VALUES (?, ?, ?)
                    ON CONFLICT(offerKey) DO NOTHING
                    """,
                arguments: [offerKey, skillID, timestamp])
            try database.execute(
                sql: "DELETE FROM skillOfferProposal WHERE offerKey = ?",
                arguments: [offerKey])
        }
    }

    public func dismissedSkillOffers(
        offerKeys: [String]
    ) async throws -> Set<String> {
        guard !offerKeys.isEmpty else { return [] }
        return try await database.read { database in
            Set(try String.fetchAll(
                database,
                sql: """
                    SELECT offerKey FROM skillOfferDismissal
                    WHERE offerKey IN (\(databaseQuestionMarks(count: offerKeys.count)))
                    """,
                arguments: StatementArguments(offerKeys)))
        }
    }

    /// Executions whose idempotency key starts with the given prefix — how a
    /// meeting finds its skill receipts, since the key embeds the subject
    /// (`recap-draft:<meetingID>`, `meeting-package-export:<meetingID>:<path>`).
    public func skillExecutions(
        idempotencyKeyPrefix prefix: String
    ) async throws -> [SkillExecutionRecord] {
        guard !prefix.isEmpty else { return [] }
        let escaped = prefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try await database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT proposalID, skillID, skillVersion, idempotencyKey,
                           state, failureCategory, attempt, updatedAt
                    FROM skillExecutionState
                    WHERE idempotencyKey LIKE ? ESCAPE '\\'
                    ORDER BY updatedAt DESC, proposalID
                    """,
                arguments: ["\(escaped)%"]
            ).map(Self.skillExecutionRecord(from:))
        }
    }
}
