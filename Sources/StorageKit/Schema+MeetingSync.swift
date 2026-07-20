import GRDB

extension StorageSchema {
    static func createMeetingSyncState(in db: Database) throws {
        try db.create(table: "meetingSyncState") { table in
            // Deliberately no meeting FK: the row is the deletion evidence
            // that must survive a user-confirmed physical purge.
            table.primaryKey("meetingID", .text)
            table.column("localGeneration", .integer).notNull().check(
                sql: "localGeneration > 0")
            table.column("acknowledgedGeneration", .integer).notNull().defaults(to: 0).check(
                sql: "acknowledgedGeneration >= 0 "
                    + "AND acknowledgedGeneration <= localGeneration")
            table.column("changedAt", .datetime).notNull()
            table.column("isDeleted", .boolean).notNull()
        }
        try db.create(
            index: "meetingSyncState_on_pending",
            on: "meetingSyncState",
            columns: ["acknowledgedGeneration", "localGeneration", "changedAt"])

        try createMeetingTriggers(in: db)
        try createMeetingOwnedTriggers(in: db)
        try createEvidenceTriggers(in: db)
        try createClaimFeedbackTriggers(in: db)
    }

    private static func createMeetingTriggers(in db: Database) throws {
        let portableColumns = [
            "title", "startedAt", "endedAt", "language", "retention", "visibility",
            "lifecycleState", "transcriptRevision", "lastProcessingError", "deletedAt"
        ]
        try createTrigger(
            "meeting_sync_ai",
            timing: "AFTER INSERT",
            table: "meeting",
            body: syncUpsert(
                meetingID: "NEW.id",
                changedAt: "NEW.updatedAt",
                isDeleted: "NEW.deletedAt IS NOT NULL",
                replaceDeletionState: true),
            in: db)
        try createTrigger(
            "meeting_sync_au",
            timing: "AFTER UPDATE OF \(portableColumns.joined(separator: ", "))",
            table: "meeting",
            body: syncUpsert(
                meetingID: "NEW.id",
                changedAt: "NEW.updatedAt",
                isDeleted: "NEW.deletedAt IS NOT NULL",
                replaceDeletionState: true),
            when: valuesChanged(portableColumns),
            in: db)
        try createTrigger(
            "meeting_sync_ad",
            timing: "AFTER DELETE",
            table: "meeting",
            body: syncUpsert(
                meetingID: "OLD.id",
                changedAt: "CURRENT_TIMESTAMP",
                isDeleted: "1",
                replaceDeletionState: true),
            in: db)
    }

    private static func createMeetingOwnedTriggers(in db: Database) throws {
        let tables: [(name: String, updateColumns: [String], timestamp: String)] = [
            (
                "speaker",
                ["label", "displayName", "isMe", "deletedAt"],
                "NEW.updatedAt"),
            (
                "segment",
                [
                    "speakerID", "channel", "text", "language", "startTime", "endTime",
                    "confidence", "isFinal", "deletedAt"
                ],
                "NEW.updatedAt"),
            (
                "summary",
                ["recipeID", "language", "markdown", "version", "fingerprint", "deletedAt"],
                "CURRENT_TIMESTAMP"),
            (
                "actionItem",
                ["text", "ownerSpeakerID", "isDone", "deletedAt"],
                "NEW.updatedAt"),
            (
                "contextItem",
                ["kind", "content", "timestamp", "deletedAt"],
                "NEW.updatedAt"),
            (
                "companionCard",
                ["question", "answer", "kind", "source", "directed", "askedAt", "deletedAt"],
                "NEW.updatedAt")
        ]
        for item in tables {
            let prefix = "\(item.name)_sync"
            try createTrigger(
                "\(prefix)_ai",
                timing: "AFTER INSERT",
                table: item.name,
                body: childSyncUpsert(
                    meetingID: "NEW.meetingID",
                    changedAt: item.name == "summary" ? "NEW.createdAt" : item.timestamp),
                in: db)
            try createTrigger(
                "\(prefix)_au",
                timing: "AFTER UPDATE OF \(item.updateColumns.joined(separator: ", "))",
                table: item.name,
                body: childSyncUpsert(
                    meetingID: "NEW.meetingID",
                    changedAt: item.timestamp),
                when: valuesChanged(item.updateColumns),
                in: db)
            try createTrigger(
                "\(prefix)_ad",
                timing: "AFTER DELETE",
                table: item.name,
                body: childSyncUpsert(
                    meetingID: "OLD.meetingID",
                    changedAt: "CURRENT_TIMESTAMP"),
                in: db)
        }
    }

    private static func createClaimFeedbackTriggers(in db: Database) throws {
        let portableColumns = ["kind", "correctionText", "deletedAt"]
        let newMeeting = feedbackMeetingID(claimID: "NEW.claimID")
        let oldMeeting = feedbackMeetingID(claimID: "OLD.claimID")
        try createTrigger(
            "summaryClaimFeedback_sync_ai",
            timing: "AFTER INSERT",
            table: "summaryClaimFeedback",
            body: childSyncUpsert(meetingID: newMeeting, changedAt: "NEW.updatedAt"),
            in: db)
        try createTrigger(
            "summaryClaimFeedback_sync_au",
            timing: "AFTER UPDATE OF \(portableColumns.joined(separator: ", "))",
            table: "summaryClaimFeedback",
            body: childSyncUpsert(meetingID: newMeeting, changedAt: "NEW.updatedAt"),
            when: valuesChanged(portableColumns),
            in: db)
        try createTrigger(
            "summaryClaimFeedback_sync_ad",
            timing: "AFTER DELETE",
            table: "summaryClaimFeedback",
            body: childSyncUpsert(meetingID: oldMeeting, changedAt: "CURRENT_TIMESTAMP"),
            in: db)
    }

    private static func createEvidenceTriggers(in db: Database) throws {
        let tables: [(name: String, updateColumns: [String])] = [
            ("summaryClaim", ["kind", "sourceTranscriptRevision"]),
            ("summaryClaimSegment", ["segmentID", "ordinal"]),
            (
                "summaryDecisionEvidence",
                ["sectionOrdinal", "bulletOrdinal", "sourceTranscriptRevision"]),
            ("summaryDecisionEvidenceSegment", ["segmentID", "ordinal"]),
            ("summaryActionItemEvidence", ["sourceTranscriptRevision"]),
            ("summaryActionItemEvidenceSegment", ["segmentID", "ordinal"]),
            ("companionCardEvidence", ["sourceTranscriptRevision"]),
            ("companionCardEvidenceSegment", ["role", "segmentID", "ordinal"])
        ]
        for item in tables {
            let prefix = "\(item.name)_sync"
            try createTrigger(
                "\(prefix)_ai",
                timing: "AFTER INSERT",
                table: item.name,
                body: childSyncUpsert(
                    meetingID: evidenceMeetingID(table: item.name, row: "NEW"),
                    changedAt: "CURRENT_TIMESTAMP"),
                in: db)
            try createTrigger(
                "\(prefix)_au",
                timing: "AFTER UPDATE OF \(item.updateColumns.joined(separator: ", "))",
                table: item.name,
                body: childSyncUpsert(
                    meetingID: evidenceMeetingID(table: item.name, row: "NEW"),
                    changedAt: "CURRENT_TIMESTAMP"),
                when: valuesChanged(item.updateColumns),
                in: db)
            try createTrigger(
                "\(prefix)_ad",
                timing: "AFTER DELETE",
                table: item.name,
                body: childSyncUpsert(
                    meetingID: evidenceMeetingID(table: item.name, row: "OLD"),
                    changedAt: "CURRENT_TIMESTAMP"),
                in: db)
        }
    }

    // Evidence rows use typed parent identities instead of duplicating a
    // meeting key. Resolve the aggregate only inside the same transaction.
    private static func evidenceMeetingID(table: String, row: String) -> String {
        switch table {
        case "summaryClaim":
            return "(SELECT meetingID FROM summary WHERE id = \(row).summaryID)"
        case "summaryClaimSegment":
            return """
            (SELECT summary.meetingID
               FROM summaryClaim
               JOIN summary ON summary.id = summaryClaim.summaryID
              WHERE summaryClaim.id = \(row).claimID)
            """
        case "summaryDecisionEvidence":
            return "(SELECT meetingID FROM summary WHERE id = \(row).summaryID)"
        case "summaryDecisionEvidenceSegment":
            return """
            (SELECT summary.meetingID
               FROM summaryDecisionEvidence
               JOIN summary ON summary.id = summaryDecisionEvidence.summaryID
              WHERE summaryDecisionEvidence.id = \(row).decisionID)
            """
        case "summaryActionItemEvidence":
            return "(SELECT meetingID FROM actionItem WHERE id = \(row).actionItemID)"
        case "summaryActionItemEvidenceSegment":
            return """
            (SELECT actionItem.meetingID
               FROM summaryActionItemEvidence
               JOIN actionItem ON actionItem.id = summaryActionItemEvidence.actionItemID
              WHERE summaryActionItemEvidence.id = \(row).evidenceID)
            """
        case "companionCardEvidence":
            return "(SELECT meetingID FROM companionCard WHERE id = \(row).cardID)"
        case "companionCardEvidenceSegment":
            return """
            (SELECT companionCard.meetingID
               FROM companionCardEvidence
               JOIN companionCard ON companionCard.id = companionCardEvidence.cardID
              WHERE companionCardEvidence.id = \(row).evidenceID)
            """
        default:
            preconditionFailure("unsupported sync evidence table: \(table)")
        }
    }

    private static func feedbackMeetingID(claimID: String) -> String {
        """
        (SELECT summary.meetingID
           FROM summaryClaim
           JOIN summary ON summary.id = summaryClaim.summaryID
          WHERE summaryClaim.id = \(claimID))
        """
    }

    private static func childSyncUpsert(meetingID: String, changedAt: String) -> String {
        syncUpsert(
            meetingID: meetingID,
            changedAt: changedAt,
            isDeleted: "COALESCE((SELECT deletedAt IS NOT NULL FROM meeting "
                + "WHERE id = \(meetingID)), 1)",
            replaceDeletionState: false)
    }

    private static func valuesChanged(_ columns: [String]) -> String {
        columns
            .map { "OLD.\($0) IS NOT NEW.\($0)" }
            .joined(separator: " OR ")
    }

    private static func syncUpsert(
        meetingID: String,
        changedAt: String,
        isDeleted: String,
        replaceDeletionState: Bool
    ) -> String {
        let deletionUpdate = replaceDeletionState
            ? "isDeleted = excluded.isDeleted"
            : "isDeleted = meetingSyncState.isDeleted"
        return """
        INSERT INTO meetingSyncState (
            meetingID, localGeneration, acknowledgedGeneration, changedAt, isDeleted
        )
        SELECT \(meetingID), 1, 0, \(changedAt), \(isDeleted)
        WHERE \(meetingID) IS NOT NULL
        ON CONFLICT(meetingID) DO UPDATE SET
            localGeneration = meetingSyncState.localGeneration + 1,
            changedAt = excluded.changedAt,
            \(deletionUpdate);
        """
    }

    private static func createTrigger(
        _ name: String,
        timing: String,
        table: String,
        body: String,
        when condition: String? = nil,
        in db: Database
    ) throws {
        let conditionSQL = condition.map { " WHEN (\($0))" } ?? ""
        try db.execute(sql: """
            CREATE TRIGGER \(name) \(timing) ON \(table)\(conditionSQL)
            BEGIN
                \(body)
            END
            """)
    }
}
