import Foundation
import GRDB

/// The v1 schema, executing the D4 contract frozen since M0:
///
/// - UUID primary keys everywhere (never auto-increment).
/// - `updatedAt` + `deletedAt` tombstones on every syncable table.
/// - Summaries are immutable versioned snapshots (action items are the
///   deliberate mutable exception: users check them off, so they live in
///   their own table keyed to a snapshot).
/// - No absolute file paths in the database — audio resolves relative to
///   the app's audio root.
/// - API keys and voiceprints never live in SQLite (Keychain / encrypted
///   files respectively).
/// - `visibility` reserved since v1 for the sharing ladder (D12).
///
/// sqlite-vec (embeddings for local RAG) intentionally waits for M8 — it
/// needs a C extension and nothing before RAG reads vectors.
public enum StorageSchema {
    public static let version = 8

    // Sequential migration registry (one per schema version);
    // inherently long body that grows with each migration.
    // swiftlint:disable:next function_body_length
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("language", .text)
                t.column("audioDirectory", .text)
                t.column("retention", .text).notNull()
                t.column("visibility", .text).notNull().defaults(to: "private")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }

            try db.create(table: "speaker") { t in
                t.primaryKey("id", .text)
                t.column("meetingID", .text).notNull().indexed()
                    .references("meeting", onDelete: .cascade)
                t.column("label", .text).notNull()
                t.column("displayName", .text)
                t.column("isMe", .boolean).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }

            try db.create(table: "segment") { t in
                t.primaryKey("id", .text)
                t.column("meetingID", .text).notNull().indexed()
                    .references("meeting", onDelete: .cascade)
                t.column("speakerID", .text).indexed()
                t.column("channel", .text).notNull()
                t.column("text", .text).notNull()
                t.column("language", .text)
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("confidence", .double)
                t.column("isFinal", .boolean).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }

            // Immutable snapshot: rows are only ever inserted (or
            // tombstoned for sync); a (meeting, recipe) pair grows a new
            // version per pass.
            try db.create(table: "summary") { t in
                t.primaryKey("id", .text)
                t.column("meetingID", .text).notNull().indexed()
                    .references("meeting", onDelete: .cascade)
                t.column("recipeID", .text).notNull()
                t.column("language", .text).notNull()
                t.column("markdown", .text).notNull()
                t.column("version", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
                t.uniqueKey(["meetingID", "recipeID", "version"])
            }

            try db.create(table: "actionItem") { t in
                t.primaryKey("id", .text)
                t.column("summaryID", .text).notNull().indexed()
                    .references("summary", onDelete: .cascade)
                t.column("meetingID", .text).notNull().indexed()
                t.column("text", .text).notNull()
                t.column("ownerSpeakerID", .text)
                t.column("isDone", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }

            // Full-text search over segment text, kept in sync with the
            // content table by GRDB-generated triggers.
            try db.create(virtualTable: "segmentSearch", using: FTS5()) { t in
                t.synchronize(withTable: "segment")
                t.tokenizer = .unicode61()
                t.column("text")
            }
        }

        // v2 (M8): per-segment sentence embedding for local RAG. A plain
        // BLOB (Float32 LE, L2-normalized) + brute-force cosine — at
        // meeting scale this beats carrying a C extension; sqlite-vec
        // arrives when the numbers say so (D19).
        migrator.registerMigration("v2") { db in
            try db.alter(table: "segment") { t in
                t.add(column: "embedding", .blob)
            }
        }

        // v3 (M10/D28): the user's own notes during the meeting — intent
        // that guides the summary. Timestamped to interleave with the
        // transcript; tombstoned like everything else (D4).
        migrator.registerMigration("v3") { db in
            try db.create(table: "contextItem") { t in
                t.primaryKey("id", .text)
                t.column("meetingID", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("content", .text).notNull()
                t.column("timestamp", .double).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(index: "contextItem_on_meetingID", on: "contextItem", columns: ["meetingID"])
        }

        // v4 (D25): material fingerprint per summary snapshot — the cache
        // key that makes regenerating free and turns a snapshot in another
        // language into a translation pivot. Nullable: old snapshots simply
        // never match.
        migrator.registerMigration("v4") { db in
            try db.alter(table: "summary") { t in
                t.add(column: "fingerprint", .text)
            }
        }

        // v5 (D26): the live Companion's answer cards, kept so the meeting can
        // be reviewed afterward instead of the cards dying with the session.
        // Timestamped (askedAt) to interleave with the transcript; tombstoned
        // like everything else (D4).
        migrator.registerMigration("v5") { db in
            try db.create(table: "companionCard") { t in
                t.primaryKey("id", .text)
                t.column("meetingID", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("question", .text).notNull()
                t.column("answer", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("source", .text).notNull()
                t.column("directed", .boolean).notNull()
                t.column("askedAt", .double).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(
                index: "companionCard_on_meetingID", on: "companionCard", columns: ["meetingID"])
        }

        // v6 (D36/Band 1): one additive durability foundation. Runtime
        // adoption remains incremental: existing meetings keep their legacy
        // audioDirectory read path until later Strangler slices create assets.
        migrator.registerMigration("v6") { db in
            try addMeetingDurabilityColumns(to: db)
            try createAudioAssetTable(in: db)
            try createGenerationRunTable(in: db)
            try addGenerationRunReferences(to: db)
            try createProcessingJobTable(in: db)
            try createOutboxEventTable(in: db)
            try createMeetingPreferenceTable(in: db)
        }

        // v7 (D75/Band 3H): content-free privacy receipts. The coverage
        // boundary prevents an upgraded library from claiming that historical
        // silence proves old meetings never left the device.
        migrator.registerMigration("v7") { db in
            try createDataEgressEventTable(in: db)
            try createPrivacyReceiptCoverage(in: db)
        }

        // v8 (D86/Band 5A): canonical people are additive and confirmation-
        // safe. Aliases are lookup evidence only; duplicate aliases across
        // different people remain valid and never imply an automatic merge.
        migrator.registerMigration("v8") { db in
            try createPersonTables(in: db)
            try addPersonReferenceToSpeaker(in: db)
        }

        return migrator
    }

    private static func addMeetingDurabilityColumns(to db: Database) throws {
        try db.alter(table: "meeting") { t in
            t.add(column: "lifecycleState", .text)
                .notNull()
                .defaults(to: "ready")
                .check(sql: "lifecycleState IN "
                    + "('recording', 'captured', 'processing', 'ready', 'needsAttention')")
            t.add(column: "transcriptRevision", .integer)
                .notNull()
                .defaults(to: 0)
                .check(sql: "transcriptRevision >= 0")
            t.add(column: "lastProcessingError", .text)
        }
    }

    private static func createAudioAssetTable(in db: Database) throws {
        try db.create(table: "audioAsset") { t in
            t.primaryKey("id", .text)
            t.column("meetingID", .text).notNull()
                .references("meeting", onDelete: .cascade)
            t.column("channel", .text).notNull().check(sql: "length(trim(channel)) > 0")
            t.column("role", .text).notNull().check(sql: "length(trim(role)) > 0")
            t.column("relativePath", .text).notNull().unique().check(
                sql: "relativePath <> '' AND substr(relativePath, 1, 1) <> '/' "
                    + "AND relativePath <> '..' AND relativePath NOT LIKE '../%' "
                    + "AND relativePath NOT LIKE '%/../%' AND relativePath NOT LIKE '%/..'")
            t.column("container", .text)
            t.column("codec", .text)
            t.column("sampleRate", .double).check(sql: "sampleRate IS NULL OR sampleRate > 0")
            t.column("channelCount", .integer).check(
                sql: "channelCount IS NULL OR channelCount > 0")
            t.column("durationSeconds", .double).check(
                sql: "durationSeconds IS NULL OR durationSeconds >= 0")
            t.column("byteCount", .integer).check(sql: "byteCount IS NULL OR byteCount >= 0")
            t.column("sha256", .text).check(sql: "sha256 IS NULL OR length(sha256) = 64")
            t.column("healthStatus", .text).notNull().defaults(to: "pending").check(
                sql: "healthStatus IN "
                    + "('pending', 'healthy', 'silent', 'clipped', 'corrupt', 'missing')")
            t.column("peakDBFS", .double)
            t.column("rmsDBFS", .double)
            t.column("sourceAssetID", .text).references("audioAsset", onDelete: .setNull)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("supersededAt", .datetime)
            t.column("deletedAt", .datetime)
        }
        try db.create(
            index: "audioAsset_on_meetingID", on: "audioAsset", columns: ["meetingID"])
        try db.create(
            index: "audioAsset_on_sourceAssetID", on: "audioAsset", columns: ["sourceAssetID"])
    }

    private static func createGenerationRunTable(in db: Database) throws {
        try db.create(table: "generationRun") { t in
            t.primaryKey("id", .text)
            t.column("meetingID", .text).notNull()
                .references("meeting", onDelete: .cascade)
            t.column("kind", .text).notNull().check(sql: "length(trim(kind)) > 0")
            t.column("providerID", .text).notNull().check(sql: "length(trim(providerID)) > 0")
            t.column("modelID", .text).notNull().check(sql: "length(trim(modelID)) > 0")
            t.column("modelRevision", .text)
            t.column("inputFingerprint", .text).notNull().check(
                sql: "length(trim(inputFingerprint)) > 0")
            t.column("configJSON", .text).notNull()
            t.column("outputLanguage", .text)
            t.column("startedAt", .datetime).notNull()
            t.column("finishedAt", .datetime)
            t.column("outcome", .text).check(
                sql: "outcome IS NULL OR outcome IN ('succeeded', 'failed', 'cancelled')")
            t.column("metricsJSON", .text)
        }
        try db.create(
            index: "generationRun_on_meetingID", on: "generationRun", columns: ["meetingID"])
    }

    private static func addGenerationRunReferences(to db: Database) throws {
        for table in ["segment", "summary", "companionCard"] {
            try db.alter(table: table) { t in
                t.add(column: "generationRunID", .text)
                    .references("generationRun", onDelete: .setNull)
            }
            try db.create(
                index: "\(table)_on_generationRunID", on: table,
                columns: ["generationRunID"])
        }
    }

    private static func createProcessingJobTable(in db: Database) throws {
        try db.create(table: "processingJob") { t in
            t.primaryKey("id", .text)
            t.column("meetingID", .text).notNull()
                .references("meeting", onDelete: .cascade)
            t.column("kind", .text).notNull().check(sql: "length(trim(kind)) > 0")
            t.column("inputFingerprint", .text).notNull().check(
                sql: "length(trim(inputFingerprint)) > 0")
            t.column("state", .text).notNull().defaults(to: "pending").check(
                sql: "state IN ('pending', 'running', 'succeeded', 'failed', 'cancelled')")
            t.column("priority", .integer).notNull().defaults(to: 0)
            t.column("progress", .double).notNull().defaults(to: 0).check(
                sql: "progress >= 0 AND progress <= 1")
            t.column("attempt", .integer).notNull().defaults(to: 0).check(
                sql: "attempt >= 0")
            t.column("maxAttempts", .integer).notNull().defaults(to: 3).check(
                sql: "maxAttempts > 0 AND attempt <= maxAttempts")
            t.column("notBefore", .datetime)
            t.column("leaseOwner", .text)
            t.column("leaseExpiresAt", .datetime)
            t.column("errorCode", .text)
            t.column("errorMessage", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("startedAt", .datetime)
            t.column("finishedAt", .datetime)
            t.column("updatedAt", .datetime).notNull()
            t.uniqueKey(["meetingID", "kind", "inputFingerprint"])
        }
        try db.create(
            index: "processingJob_on_meetingID", on: "processingJob", columns: ["meetingID"])
        try db.create(
            index: "processingJob_on_dispatch", on: "processingJob",
            columns: ["state", "notBefore", "priority"])
    }

    private static func createOutboxEventTable(in db: Database) throws {
        try db.create(table: "outboxEvent") { t in
            t.primaryKey("id", .text)
            t.column("aggregateID", .text).notNull()
            t.column("kind", .text).notNull().check(sql: "length(trim(kind)) > 0")
            t.column("idempotencyKey", .text).notNull().unique()
            t.column("payloadJSON", .text).notNull()
            t.column("state", .text).notNull().defaults(to: "pending").check(
                sql: "state IN ('pending', 'delivering', 'delivered', 'failed')")
            t.column("attempts", .integer).notNull().defaults(to: 0).check(
                sql: "attempts >= 0")
            t.column("nextAttemptAt", .datetime)
            t.column("createdAt", .datetime).notNull()
            t.column("deliveredAt", .datetime)
        }
        try db.create(
            index: "outboxEvent_on_dispatch", on: "outboxEvent",
            columns: ["state", "nextAttemptAt"])
    }

    private static func createMeetingPreferenceTable(in db: Database) throws {
        try db.create(table: "meetingPreference") { t in
            t.primaryKey("meetingID", .text).references("meeting", onDelete: .cascade)
            t.column("transcriptLanguageMode", .text).notNull().defaults(to: "automatic")
            t.column("transcriptLanguage", .text)
            t.column("summaryLanguageMode", .text).notNull().defaults(to: "followSpokenLanguage")
            t.column("summaryLanguage", .text)
            t.column("recipeID", .text)
            t.column("summaryEngineID", .text)
            t.column("refineEngineID", .text)
            t.column("updatedAt", .datetime).notNull()
            t.check(sql: "(transcriptLanguageMode = 'automatic' "
                + "AND transcriptLanguage IS NULL) OR (transcriptLanguageMode = 'fixed' "
                + "AND transcriptLanguage IS NOT NULL "
                + "AND length(trim(transcriptLanguage)) > 0)")
            t.check(sql: "(summaryLanguageMode = 'followSpokenLanguage' "
                + "AND summaryLanguage IS NULL) OR (summaryLanguageMode = 'fixed' "
                + "AND summaryLanguage IS NOT NULL "
                + "AND length(trim(summaryLanguage)) > 0)")
        }
    }

    private static func createDataEgressEventTable(in db: Database) throws {
        try db.create(table: "dataEgressEvent") { t in
            t.primaryKey("id", .text)
            t.column("meetingID", .text).notNull()
                .references("meeting", onDelete: .cascade)
            t.column("operation", .text).notNull().check(
                sql: "operation IN ('companion-knowledge-answer', 'summary-generation', "
                    + "'publish-github-gist', 'create-github-issue', 'create-linear-issue')")
            t.column("destinationScope", .text).notNull().check(
                sql: "destinationScope IN ('local-device', 'remote')")
            t.column("destinationHost", .text).notNull().check(
                sql: "length(trim(destinationHost)) > 0")
            t.column("dataClassification", .text).notNull().check(
                sql: "dataClassification IN ('meeting-question-only', "
                    + "'meeting-summary-material', 'meeting-export-document', "
                    + "'meeting-action-item')")
            t.column("consentSource", .text).notNull().check(
                sql: "consentSource IN ('companion-byok-settings', "
                    + "'explicit-companion-client', 'summary-engine-settings', "
                    + "'explicit-summary-provider', 'explicit-gist-publish', "
                    + "'explicit-github-issue-publish', 'explicit-linear-issue-publish')")
            t.column("providerID", .text).notNull().check(
                sql: "length(trim(providerID)) > 0")
            t.column("modelID", .text)
            t.column("attemptedAt", .datetime).notNull()
        }
        try db.create(
            index: "dataEgressEvent_on_meetingID_attemptedAt",
            on: "dataEgressEvent",
            columns: ["meetingID", "attemptedAt"])
    }

    private static func createPrivacyReceiptCoverage(in db: Database) throws {
        try db.create(table: "privacyReceiptCoverage") { t in
            t.primaryKey("id", .text).check(sql: "id = 'meeting-content-egress'")
            t.column("trackingStartedAt", .datetime).notNull()
        }
        try db.execute(
            sql: "INSERT INTO privacyReceiptCoverage (id, trackingStartedAt) VALUES (?, ?)",
            arguments: ["meeting-content-egress", Date()])
    }

    private static func createPersonTables(in db: Database) throws {
        try db.create(table: "person") { t in
            t.primaryKey("id", .text)
            t.column("preferredName", .text).notNull().check(
                sql: "length(trim(preferredName)) > 0")
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("deletedAt", .datetime)
        }
        try db.create(table: "personAlias") { t in
            t.primaryKey("id", .text)
            t.column("personID", .text).notNull()
                .references("person", onDelete: .cascade)
            t.column("normalizedAlias", .text).notNull().check(
                sql: "length(trim(normalizedAlias)) > 0")
            t.column("source", .text).notNull().check(
                sql: "source IN ('manual-name', 'transcript-suggestion', 'voice-suggestion')")
            t.column("confidence", .double).notNull().check(
                sql: "confidence >= 0 AND confidence <= 1")
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("deletedAt", .datetime)
            t.uniqueKey(["personID", "normalizedAlias"])
        }
        try db.create(
            index: "personAlias_on_normalizedAlias",
            on: "personAlias",
            columns: ["normalizedAlias"])
    }

    private static func addPersonReferenceToSpeaker(in db: Database) throws {
        try db.alter(table: "speaker") { t in
            t.add(column: "personID", .text)
                .references("person", onDelete: .setNull)
        }
        try db.create(
            index: "speaker_on_personID",
            on: "speaker",
            columns: ["personID"])
    }
}
