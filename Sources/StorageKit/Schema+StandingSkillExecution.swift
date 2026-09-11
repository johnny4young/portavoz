import Foundation
import GRDB
import PortavozCore

extension StorageSchema {
    /// v47: immutable standing-rule authority receipts plus one bounded local
    /// artifact. The receipt intentionally snapshots `ruleID` without a
    /// foreign key so deleting the current rule cannot erase its history.
    static func registerStandingSkillExecutionMigration(
        in migrator: inout DatabaseMigrator
    ) {
        registerStandingSkillExecutionAuthorityMigration(in: &migrator)
        registerStandingOccurrenceCanonicalizationMigration(in: &migrator)
    }
}

private extension StorageSchema {
    static func registerStandingSkillExecutionAuthorityMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v47") { database in
            try database.create(
                table: "standingSkillExecutionAuthority"
            ) { table in
                table.primaryKey("proposalID", .text)
                    .references("skillExecutionState", onDelete: .cascade)
                table.column("ruleID", .text).notNull().check(
                    sql: "length(ruleID) = 36")
                table.column("action", .text).notNull().check(
                    sql: "action = 'prepare-pre-meeting-brief'")
                table.column("occurrenceFingerprint", .text).notNull().check(
                    sql: "length(occurrenceFingerprint) = 64")
                table.column("eventStartAt", .datetime).notNull()
                table.column("budgetWindowStart", .datetime).notNull()
                table.column("budgetWindowEnd", .datetime).notNull()
                table.column("authorizedAt", .datetime).notNull()
                table.check(sql: "budgetWindowEnd > budgetWindowStart")
                table.check(sql: "authorizedAt >= budgetWindowStart")
                table.check(sql: "authorizedAt < budgetWindowEnd")
                table.uniqueKey(["action", "occurrenceFingerprint"])
            }
            try database.create(
                index: "standingSkillExecutionAuthority_on_daily_budget",
                on: "standingSkillExecutionAuthority",
                columns: ["ruleID", "authorizedAt"])
            try createStandingAuthorityImmutabilityTrigger(in: database)

            try database.create(table: "standingSkillArtifact") { table in
                table.primaryKey("proposalID", .text)
                    .references("skillExecutionState", onDelete: .cascade)
                table.column("kind", .text).notNull().check(
                    sql: "kind = 'pre-meeting-brief'")
                table.column("formatVersion", .integer).notNull().check(
                    sql: "formatVersion = \(StandingSkillArtifact.currentFormatVersion)")
                table.column("payload", .blob).notNull().check(sql: """
                    length(payload) BETWEEN 1 AND
                        \(StandingSkillArtifact.maximumPayloadByteCount)
                    """)
                table.column("sha256", .text).notNull().check(
                    sql: "length(sha256) = 64")
                table.column("createdAt", .datetime).notNull()
            }
            try database.execute(sql: """
                CREATE TRIGGER standingSkillArtifact_no_update
                BEFORE UPDATE ON standingSkillArtifact
                BEGIN
                    SELECT RAISE(ABORT, 'standing artifact is immutable');
                END
                """)
        }
    }

    static func registerStandingOccurrenceCanonicalizationMigration(
        in migrator: inout DatabaseMigrator
    ) {
        // v48: GRDB persists Foundation dates as UTC text with millisecond
        // precision. Re-key the unreleased v47 standing authority to that
        // durable boundary instead of a transient floating-point bit pattern.
        migrator.registerMigration("v48") { database in
            let canonicalRows = try standingOccurrenceCanonicalizations(
                in: database)
            try database.execute(sql: """
                DROP TRIGGER standingSkillExecutionAuthority_no_update
                """)
            try stageStandingOccurrenceCanonicalizations(
                canonicalRows,
                in: database)
            try applyStandingOccurrenceCanonicalizations(
                canonicalRows,
                in: database)
            try createStandingAuthorityImmutabilityTrigger(in: database)
        }
    }

    static func standingOccurrenceCanonicalizations(
        in database: Database
    ) throws -> [StandingOccurrenceCanonicalization] {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT authority.proposalID, authority.ruleID,
                       authority.eventStartAt,
                       execution.proposalID AS ownerProposalID,
                       subject.subjectKind,
                       subject.calendarEventID
                FROM standingSkillExecutionAuthority AS authority
                LEFT JOIN skillExecutionState AS execution
                  ON execution.proposalID = authority.proposalID
                LEFT JOIN skillExecutionSubject AS subject
                  ON subject.proposalID = authority.proposalID
                ORDER BY authority.proposalID ASC
                """)
        return try rows.map { row in
            let rawProposalID: String = row["proposalID"]
            let rawRuleID: String = row["ruleID"]
            let rawOwnerID: String? = row["ownerProposalID"]
            let rawSubjectKind: String? = row["subjectKind"]
            let rawEventID: String? = row["calendarEventID"]
            let eventStartAt: Date = row["eventStartAt"]
            guard let proposalID = UUID(uuidString: rawProposalID),
                  let ruleUUID = UUID(uuidString: rawRuleID),
                  rawOwnerID == rawProposalID,
                  rawSubjectKind == "calendar-event",
                  let eventID = rawEventID
            else {
                throw StorageError.invalidStandingSkillExecution(
                    "v48 occurrence identity is incomplete")
            }
            let occurrence = StandingSkillOccurrence(
                eventID: eventID,
                eventStartAt: eventStartAt)
            guard occurrence.isValid else {
                throw StorageError.invalidStandingSkillExecution(
                    "v48 occurrence identity is invalid")
            }
            return StandingOccurrenceCanonicalization(
                proposalID: proposalID,
                ruleID: StandingSkillRuleID(rawValue: ruleUUID),
                occurrence: occurrence)
        }
    }

    static func stageStandingOccurrenceCanonicalizations(
        _ rows: [StandingOccurrenceCanonicalization],
        in database: Database
    ) throws {
        for row in rows {
            let proposal = row.proposalID.uuidString.lowercased()
            let stagedFingerprint = OperationFingerprint.make(
                version: "standing-skill-occurrence-v48-stage",
                components: [proposal])
            try database.execute(
                sql: """
                    UPDATE standingSkillExecutionAuthority
                    SET occurrenceFingerprint = ?
                    WHERE proposalID = ?
                    """,
                arguments: [stagedFingerprint, row.proposalID.uuidString])
            try database.execute(
                sql: """
                    UPDATE skillExecutionState
                    SET idempotencyKey = ?
                    WHERE proposalID = ?
                    """,
                arguments: [
                    "standing-skill-v48-stage:\(proposal)",
                    row.proposalID.uuidString
                ])
        }
    }

    static func applyStandingOccurrenceCanonicalizations(
        _ rows: [StandingOccurrenceCanonicalization],
        in database: Database
    ) throws {
        for row in rows {
            try database.execute(
                sql: """
                    UPDATE standingSkillExecutionAuthority
                    SET occurrenceFingerprint = ?
                    WHERE proposalID = ?
                    """,
                arguments: [
                    row.occurrence.fingerprint,
                    row.proposalID.uuidString
                ])
            try database.execute(
                sql: """
                    UPDATE skillExecutionState
                    SET idempotencyKey = ?
                    WHERE proposalID = ?
                    """,
                arguments: [
                    StandingSkillExecutionIdentity.idempotencyKey(
                        ruleID: row.ruleID,
                        occurrence: row.occurrence),
                    row.proposalID.uuidString
                ])
        }
    }
}

private struct StandingOccurrenceCanonicalization {
    let proposalID: UUID
    let ruleID: StandingSkillRuleID
    let occurrence: StandingSkillOccurrence
}

private extension StorageSchema {
    static func createStandingAuthorityImmutabilityTrigger(
        in database: Database
    ) throws {
        try database.execute(sql: """
            CREATE TRIGGER standingSkillExecutionAuthority_no_update
            BEFORE UPDATE ON standingSkillExecutionAuthority
            BEGIN
                SELECT RAISE(ABORT, 'standing authority is immutable');
            END
            """)
    }
}
