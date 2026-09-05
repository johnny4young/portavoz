import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    public static let maximumSkillOfferReconciliationCount = 200
    public static let maximumSkillOfferReviewCount = 100

    /// Reconciles only identities a bounded producer just evaluated. An offer
    /// is returned to SwiftUI only after this write succeeds, so the central
    /// authority can never claim less than the subject surface showed.
    public func reconcileSkillOffers(
        candidateOfferKeys: [String],
        active offers: [SkillOfferRegistration]
    ) async throws {
        let candidateSet = Set(candidateOfferKeys)
        let activeKeys = Set(offers.map(\.offerKey))
        guard candidateOfferKeys.count <= Self.maximumSkillOfferReconciliationCount,
              candidateSet.count == candidateOfferKeys.count,
              offers.count <= candidateOfferKeys.count,
              activeKeys.count == offers.count,
              activeKeys.isSubset(of: candidateSet),
              candidateOfferKeys.allSatisfy(Self.isValidSkillOfferKey),
              offers.allSatisfy(\.isValid)
        else { throw StorageError.invalidSkillOffer("invalid reconciliation batch") }

        try await database.write { database in
            let retired = candidateSet.subtracting(activeKeys)
            let dismissed = activeKeys.isEmpty
                ? Set<String>()
                : Set(try String.fetchAll(
                    database,
                    sql: """
                        SELECT offerKey FROM skillOfferDismissal
                        WHERE offerKey IN (\(databaseQuestionMarks(
                            count: activeKeys.count)))
                        """,
                    arguments: StatementArguments(activeKeys.sorted())))
            let authorityToRemove = retired.union(dismissed)
            if !authorityToRemove.isEmpty {
                try database.execute(
                    sql: """
                        DELETE FROM skillOfferProposal
                        WHERE offerKey IN (\(databaseQuestionMarks(
                            count: authorityToRemove.count)))
                        """,
                    arguments: StatementArguments(authorityToRemove.sorted()))
            }
            for offer in offers where !dismissed.contains(offer.offerKey) {
                try Self.upsertSkillOffer(offer, in: database)
            }
        }
    }

    /// Durably dismisses one proposal using only the unrelated review UUID
    /// exposed to Settings. Storage resolves the stable offer intent and
    /// writes its terminal tombstone in the same transaction; no subject
    /// identity or offer key crosses back into presentation.
    public func dismissProposedSkillOffer(
        reviewID: UUID,
        at timestamp: Date = Date()
    ) async throws -> SkillOfferReviewDismissalOutcome {
        guard timestamp.timeIntervalSinceReferenceDate.isFinite else {
            throw StorageError.invalidSkillOffer("invalid dismissal timestamp")
        }

        return try await database.write { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT offerKey, skillID, expiresAt
                    FROM skillOfferProposal
                    WHERE reviewID = ?
                    """,
                arguments: [reviewID.uuidString])
            else { return .unavailable }

            let offerKey: String = row["offerKey"]
            let skillID: String = row["skillID"]
            let expiresAt: Date? = row["expiresAt"]
            guard Self.isValidSkillOfferKey(offerKey),
                  !skillID.isEmpty,
                  skillID == skillID.trimmingCharacters(
                      in: .whitespacesAndNewlines),
                  skillID.utf8.count <= SkillDefinition.maximumIDByteCount
            else {
                throw StorageError.invalidPersistedValue(
                    table: "skillOfferProposal",
                    column: "reviewID",
                    value: reviewID.uuidString)
            }
            if let expiresAt, expiresAt <= timestamp {
                try database.execute(
                    sql: "DELETE FROM skillOfferProposal WHERE reviewID = ?",
                    arguments: [reviewID.uuidString])
                return .unavailable
            }

            try database.execute(
                sql: """
                    INSERT INTO skillOfferDismissal (
                        offerKey, skillID, dismissedAt
                    ) VALUES (?, ?, ?)
                    ON CONFLICT(offerKey) DO NOTHING
                    """,
                arguments: [offerKey, skillID, timestamp])
            try database.execute(
                sql: "DELETE FROM skillOfferProposal WHERE reviewID = ?",
                arguments: [reviewID.uuidString])
            return .dismissed
        }
    }

    /// Resolves one opaque review identity only after an explicit user action.
    /// The subject crosses this boundary transiently for navigation; the
    /// bounded review list remains subject-free and no effect is admitted.
    public func resolveProposedSkillOfferSubject(
        reviewID: UUID,
        at timestamp: Date = Date()
    ) async throws -> SkillOfferReviewSubjectOutcome {
        guard timestamp.timeIntervalSinceReferenceDate.isFinite else {
            throw StorageError.invalidSkillOffer("invalid review timestamp")
        }

        return try await database.write { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT skillID, skillVersion, reason, subjectKind,
                           meetingID, commitmentID, calendarEventID, expiresAt
                    FROM skillOfferProposal
                    WHERE reviewID = ?
                      AND NOT EXISTS (
                          SELECT 1 FROM skillOfferDismissal
                          WHERE skillOfferDismissal.offerKey =
                              skillOfferProposal.offerKey
                      )
                      AND NOT EXISTS (
                          SELECT 1 FROM skillDisablement
                          WHERE skillDisablement.skillID =
                              skillOfferProposal.skillID
                      )
                    """,
                arguments: [reviewID.uuidString])
            else { return .unavailable }

            let expiresAt: Date? = row["expiresAt"]
            guard expiresAt?.timeIntervalSinceReferenceDate.isFinite ?? true
            else {
                throw StorageError.invalidPersistedValue(
                    table: "skillOfferProposal",
                    column: "expiresAt",
                    value: reviewID.uuidString)
            }
            if let expiresAt, expiresAt <= timestamp {
                try database.execute(
                    sql: "DELETE FROM skillOfferProposal WHERE reviewID = ?",
                    arguments: [reviewID.uuidString])
                return .unavailable
            }

            return .active(try Self.skillOfferReviewSubjectRecord(from: row))
        }
    }

    /// Newest active offers, bounded before materialization. Expired external
    /// subjects are pruned in the same transaction so they cannot accumulate
    /// ahead of the LIMIT and turn the ordered index walk into a time cliff.
    public func proposedSkillOffers(
        limit: Int,
        at now: Date = Date()
    ) async throws -> [SkillOfferReviewRecord] {
        guard (1...Self.maximumSkillOfferReviewCount).contains(limit),
              now.timeIntervalSinceReferenceDate.isFinite
        else { return [] }

        return try await database.write { database in
            try database.execute(
                sql: "DELETE FROM skillOfferProposal WHERE expiresAt <= ?",
                arguments: [now])
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT offerKey, reviewID, skillID, skillVersion, reason,
                           proposedAt, lastObservedAt
                    FROM skillOfferProposal INDEXED BY skillOfferProposal_on_review
                    WHERE NOT EXISTS (
                        SELECT 1 FROM skillOfferDismissal
                        WHERE skillOfferDismissal.offerKey = skillOfferProposal.offerKey
                    )
                      AND NOT EXISTS (
                        SELECT 1 FROM skillDisablement
                        WHERE skillDisablement.skillID = skillOfferProposal.skillID
                    )
                    ORDER BY lastObservedAt DESC, offerKey ASC
                    LIMIT ?
                    """,
                arguments: [limit])
            let keys = rows.map { $0["offerKey"] as String }
            let classes = try Self.skillOfferInputDataClasses(
                offerKeys: keys,
                in: database)
            return try rows.map { row in
                let key: String = row["offerKey"]
                guard let inputDataClasses = classes[key],
                      !inputDataClasses.isEmpty
                else {
                    throw StorageError.invalidPersistedValue(
                        table: "skillOfferProposalInput",
                        column: "offerKey",
                        value: key)
                }
                return try Self.skillOfferReviewRecord(
                    from: row,
                    inputDataClasses: inputDataClasses)
            }
        }
    }

    private static func upsertSkillOffer(
        _ offer: SkillOfferRegistration,
        in database: Database
    ) throws {
        let existing = try Row.fetchOne(
            database,
            sql: """
                SELECT skillID, skillVersion, reason, subjectKind,
                       meetingID, commitmentID, calendarEventID
                FROM skillOfferProposal WHERE offerKey = ?
                """,
            arguments: [offer.offerKey])

        if let existing {
            let existingVersion: Int = existing["skillVersion"]
            guard existingVersion <= offer.definition.version else {
                throw StorageError.invalidSkillOffer(
                    "a newer Skill definition already owns this offer")
            }
            try validateSkillOfferIdentity(offer, against: existing)
            if existingVersion == offer.definition.version {
                let persistedClasses = try skillOfferInputDataClasses(
                    offerKeys: [offer.offerKey],
                    in: database)[offer.offerKey] ?? []
                guard persistedClasses == offer.requestedInputDataClasses else {
                    throw StorageError.invalidSkillOffer(
                        "the same Skill version changed its input declaration")
                }
            } else {
                try updateSkillOfferDefinition(offer, in: database)
            }
            try database.execute(
                sql: """
                    UPDATE skillOfferProposal
                    SET lastObservedAt = MAX(lastObservedAt, ?), expiresAt = ?
                    WHERE offerKey = ?
                    """,
                arguments: [offer.proposedAt, offer.expiresAt, offer.offerKey])
            return
        }

        let subject = subjectColumns(offer.subject)
        try database.execute(
            sql: """
                INSERT INTO skillOfferProposal (
                    offerKey, reviewID, skillID, skillVersion, reason,
                    subjectKind, meetingID, commitmentID, calendarEventID,
                    proposedAt, lastObservedAt, expiresAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                offer.offerKey,
                UUID().uuidString,
                offer.definition.id,
                offer.definition.version,
                offer.reason.rawValue,
                offer.subject.kind.rawValue,
                subject.meetingID,
                subject.commitmentID,
                subject.calendarEventID,
                offer.proposedAt,
                offer.proposedAt,
                offer.expiresAt
            ])
        try replaceSkillOfferInputDataClasses(offer, in: database)
    }

    private static func validateSkillOfferIdentity(
        _ offer: SkillOfferRegistration,
        against row: Row
    ) throws {
        let subject = subjectColumns(offer.subject)
        let persistedSkillID: String = row["skillID"]
        let persistedReason: String = row["reason"]
        let persistedKind: String = row["subjectKind"]
        let persistedMeetingID: String? = row["meetingID"]
        let persistedCommitmentID: String? = row["commitmentID"]
        let persistedCalendarEventID: String? = row["calendarEventID"]
        guard persistedSkillID == offer.definition.id,
              persistedReason == offer.reason.rawValue,
              persistedKind == offer.subject.kind.rawValue,
              persistedMeetingID == subject.meetingID,
              persistedCommitmentID == subject.commitmentID,
              persistedCalendarEventID == subject.calendarEventID
        else {
            throw StorageError.invalidSkillOffer(
                "an offer key collided with another immutable intent")
        }
    }

    private static func updateSkillOfferDefinition(
        _ offer: SkillOfferRegistration,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                UPDATE skillOfferProposal
                SET skillVersion = ?
                WHERE offerKey = ?
                """,
            arguments: [offer.definition.version, offer.offerKey])
        try replaceSkillOfferInputDataClasses(offer, in: database)
    }

    private static func replaceSkillOfferInputDataClasses(
        _ offer: SkillOfferRegistration,
        in database: Database
    ) throws {
        try database.execute(
            sql: "DELETE FROM skillOfferProposalInput WHERE offerKey = ?",
            arguments: [offer.offerKey])
        for dataClass in offer.requestedInputDataClasses.sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            try database.execute(
                sql: """
                    INSERT INTO skillOfferProposalInput (offerKey, dataClass)
                    VALUES (?, ?)
                    """,
                arguments: [offer.offerKey, dataClass.rawValue])
        }
    }

    private static func skillOfferInputDataClasses(
        offerKeys: [String],
        in database: Database
    ) throws -> [String: Set<SkillInputDataClass>] {
        guard !offerKeys.isEmpty else { return [:] }
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT offerKey, dataClass
                FROM skillOfferProposalInput
                WHERE offerKey IN (\(databaseQuestionMarks(count: offerKeys.count)))
                ORDER BY offerKey, dataClass
                """,
            arguments: StatementArguments(offerKeys))
        var result: [String: Set<SkillInputDataClass>] = [:]
        for row in rows {
            let key: String = row["offerKey"]
            let raw: String = row["dataClass"]
            guard let dataClass = SkillInputDataClass(rawValue: raw) else {
                throw StorageError.invalidPersistedValue(
                    table: "skillOfferProposalInput",
                    column: "dataClass",
                    value: raw)
            }
            result[key, default: []].insert(dataClass)
        }
        return result
    }

    private static func skillOfferReviewRecord(
        from row: Row,
        inputDataClasses: Set<SkillInputDataClass>
    ) throws -> SkillOfferReviewRecord {
        let rawReviewID: String = row["reviewID"]
        let rawReason: String = row["reason"]
        let skillID: String = row["skillID"]
        let skillVersion: Int = row["skillVersion"]
        let proposedAt: Date = row["proposedAt"]
        let lastObservedAt: Date = row["lastObservedAt"]
        guard let reviewID = UUID(uuidString: rawReviewID) else {
            throw StorageError.invalidPersistedUUID(
                table: "skillOfferProposal",
                column: "reviewID",
                value: rawReviewID)
        }
        guard let reason = SkillOfferReason(rawValue: rawReason),
              !skillID.isEmpty,
              skillID == skillID.trimmingCharacters(in: .whitespacesAndNewlines),
              skillID.utf8.count <= SkillDefinition.maximumIDByteCount,
              skillVersion >= 1,
              proposedAt.timeIntervalSinceReferenceDate.isFinite,
              lastObservedAt.timeIntervalSinceReferenceDate.isFinite,
              lastObservedAt >= proposedAt
        else {
            throw StorageError.invalidPersistedValue(
                table: "skillOfferProposal",
                column: "review",
                value: rawReason)
        }
        return SkillOfferReviewRecord(
            id: reviewID,
            skillID: skillID,
            skillVersion: skillVersion,
            reason: reason,
            inputDataClasses: inputDataClasses,
            proposedAt: proposedAt,
            lastObservedAt: lastObservedAt)
    }

    private static func skillOfferReviewSubjectRecord(
        from row: Row
    ) throws -> SkillOfferReviewSubjectRecord {
        let skillID: String = row["skillID"]
        let skillVersion: Int = row["skillVersion"]
        let rawReason: String = row["reason"]
        let rawKind: String = row["subjectKind"]
        let rawMeetingID: String? = row["meetingID"]
        let rawCommitmentID: String? = row["commitmentID"]
        let calendarEventID: String? = row["calendarEventID"]
        guard let reason = SkillOfferReason(rawValue: rawReason) else {
            throw StorageError.invalidPersistedValue(
                table: "skillOfferProposal",
                column: "reason",
                value: rawReason)
        }
        guard let kind = SkillOfferSubject.Kind(rawValue: rawKind) else {
            throw StorageError.invalidPersistedValue(
                table: "skillOfferProposal",
                column: "subjectKind",
                value: rawKind)
        }

        let subject: SkillOfferSubject
        switch kind {
        case .meeting:
            guard let rawMeetingID,
                  let identifier = UUID(uuidString: rawMeetingID),
                  rawCommitmentID == nil,
                  calendarEventID == nil
            else {
                throw invalidSkillOfferReviewSubject(rawKind)
            }
            subject = .meeting(MeetingID(rawValue: identifier))
        case .commitment:
            guard let rawCommitmentID,
                  let identifier = UUID(uuidString: rawCommitmentID),
                  rawMeetingID == nil,
                  calendarEventID == nil
            else {
                throw invalidSkillOfferReviewSubject(rawKind)
            }
            subject = .commitment(CommitmentID(rawValue: identifier))
        case .calendarEvent:
            guard let calendarEventID,
                  UpcomingEvent.isValidIdentity(calendarEventID),
                  rawMeetingID == nil,
                  rawCommitmentID == nil
            else {
                throw invalidSkillOfferReviewSubject(rawKind)
            }
            subject = .calendarEvent(calendarEventID)
        }

        let record = SkillOfferReviewSubjectRecord(
            skillID: skillID,
            skillVersion: skillVersion,
            reason: reason,
            subject: subject)
        guard record.isValid else {
            throw invalidSkillOfferReviewSubject(rawKind)
        }
        return record
    }

    private static func invalidSkillOfferReviewSubject(
        _ value: String
    ) -> StorageError {
        StorageError.invalidPersistedValue(
            table: "skillOfferProposal",
            column: "subject",
            value: value)
    }

    private static func subjectColumns(
        _ subject: SkillOfferSubject
    ) -> (meetingID: String?, commitmentID: String?, calendarEventID: String?) {
        switch subject {
        case .meeting(let id):
            (id.rawValue.uuidString, nil, nil)
        case .commitment(let id):
            (nil, id.rawValue.uuidString, nil)
        case .calendarEvent(let id):
            (nil, nil, id)
        }
    }

    static func isValidSkillOfferKey(_ key: String) -> Bool {
        !key.isEmpty
            && key.utf8.count <= SkillOfferRegistration.maximumOfferKeyByteCount
    }
}
