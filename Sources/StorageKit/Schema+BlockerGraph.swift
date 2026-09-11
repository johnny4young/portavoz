import GRDB

extension StorageSchema {
    static func createBlockerGraphTables(in database: Database) throws {
        try database.create(table: "meetingMemoryGraphMeetingBlocker") { table in
            table.column("meetingID", .text).notNull()
                .references("meeting", onDelete: .cascade)
            table.column("blockerID", .text).notNull()
                .references("decisionCommitmentBlocker", onDelete: .cascade)
            table.primaryKey(["meetingID", "blockerID"])
        }
        try database.create(
            index: "meetingMemoryGraphMeetingBlocker_on_blocker",
            on: "meetingMemoryGraphMeetingBlocker",
            columns: ["blockerID", "meetingID"])

        try database.create(
            table: "meetingMemoryGraphDecisionCommitmentBlocker"
        ) { table in
            table.column("blockerID", .text).primaryKey()
                .references("decisionCommitmentBlocker", onDelete: .cascade)
            table.column("decisionID", .text).notNull()
                .references("decisionContinuity", onDelete: .cascade)
            table.column("commitmentID", .text).notNull()
                .references("commitment", onDelete: .cascade)
        }
        try database.create(
            index: "memoryGraphBlocker_on_decision",
            on: "meetingMemoryGraphDecisionCommitmentBlocker",
            columns: ["decisionID", "commitmentID"])
        try database.create(
            index: "memoryGraphBlocker_on_commitment",
            on: "meetingMemoryGraphDecisionCommitmentBlocker",
            columns: ["commitmentID", "decisionID"])
    }

    static func createBlockerGraphInvalidationTriggers(
        in database: Database
    ) throws {
        try createMemoryGraphTrigger(
            "memoryGraphDecisionCommitmentBlocker_ai",
            timing: "AFTER INSERT",
            table: "decisionCommitmentBlocker",
            scopes: """
                SELECT 'meeting' AS scopeKind, NEW.sourceMeetingID AS scopeID
                UNION SELECT 'decision', NEW.decisionID
                UNION SELECT 'commitment', NEW.commitmentID
                """,
            in: database)
        try createMemoryGraphTrigger(
            "memoryGraphDecisionCommitmentBlocker_au",
            timing: "AFTER UPDATE OF deletedAt",
            table: "decisionCommitmentBlocker",
            scopes: """
                SELECT 'meeting' AS scopeKind, NEW.sourceMeetingID AS scopeID
                UNION SELECT 'decision', NEW.decisionID
                UNION SELECT 'commitment', NEW.commitmentID
                UNION SELECT 'meeting', event.sourceMeetingID
                FROM decisionCommitmentBlockerEvent AS event
                WHERE event.blockerID = NEW.id
                """,
            when: valuesChanged(["deletedAt"]),
            in: database)
        try createMemoryGraphTrigger(
            "memoryGraphDecisionCommitmentBlocker_ad",
            timing: "AFTER DELETE",
            table: "decisionCommitmentBlocker",
            scopes: """
                SELECT 'meeting' AS scopeKind, OLD.sourceMeetingID AS scopeID
                UNION SELECT 'decision', OLD.decisionID
                UNION SELECT 'commitment', OLD.commitmentID
                """,
            in: database)
        try createMemoryGraphTrigger(
            "memoryGraphDecisionCommitmentBlockerEvent_ai",
            timing: "AFTER INSERT",
            table: "decisionCommitmentBlockerEvent",
            scopes: "SELECT 'meeting' AS scopeKind, NEW.sourceMeetingID AS scopeID",
            in: database)
        try createMemoryGraphTrigger(
            "memoryGraphDecisionCommitmentBlockerEvent_ad",
            timing: "AFTER DELETE",
            table: "decisionCommitmentBlockerEvent",
            scopes: "SELECT 'meeting' AS scopeKind, OLD.sourceMeetingID AS scopeID",
            in: database)
        try createBlockerEndpointInvalidationTriggers(in: database)
    }

    private static func createBlockerEndpointInvalidationTriggers(
        in database: Database
    ) throws {
        try createMemoryGraphTrigger(
            "memoryGraphBlockerDecision_au",
            timing: "AFTER UPDATE OF deletedAt",
            table: "decisionContinuity",
            scopes: blockerEndpointMeetingScopes(
                endpointColumn: "decisionID",
                endpointID: "NEW.id"),
            when: valuesChanged(["deletedAt"]),
            in: database)
        try createMemoryGraphTrigger(
            "memoryGraphBlockerCommitment_au",
            timing: "AFTER UPDATE OF deletedAt",
            table: "commitment",
            scopes: blockerEndpointMeetingScopes(
                endpointColumn: "commitmentID",
                endpointID: "NEW.id"),
            when: valuesChanged(["deletedAt"]),
            in: database)
    }

    private static func blockerEndpointMeetingScopes(
        endpointColumn: String,
        endpointID: String
    ) -> String {
        """
        SELECT 'meeting' AS scopeKind, blocker.sourceMeetingID AS scopeID
        FROM decisionCommitmentBlocker AS blocker
        WHERE blocker.\(endpointColumn) = \(endpointID)
          AND blocker.deletedAt IS NULL
        UNION
        SELECT 'meeting', event.sourceMeetingID
        FROM decisionCommitmentBlocker AS blocker
        JOIN decisionCommitmentBlockerEvent AS event
          ON event.blockerID = blocker.id
        WHERE blocker.\(endpointColumn) = \(endpointID)
          AND blocker.deletedAt IS NULL
        """
    }
}
