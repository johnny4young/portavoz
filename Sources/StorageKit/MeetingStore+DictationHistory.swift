import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    public static let maximumDictationPageSize = 100

    public func dictationHistoryPolicy() async throws -> DictationHistoryPolicy {
        try await database.read { try Self.dictationHistoryPolicy(in: $0) }
    }

    /// Turning saving off advances the generation so a dictation admitted
    /// earlier cannot be written; a shorter retention purges at once.
    public func setDictationHistoryPolicy(
        isEnabled: Bool, keepsOriginal: Bool, retentionDays: Int, at now: Date = Date()
    ) async throws -> DictationHistoryPolicy {
        guard DictationHistoryPolicy.retentionChoices.contains(retentionDays) else {
            throw StorageError.invalidDictationRecord("unsupported retention")
        }
        return try await database.write { database in
            let current = try Self.dictationHistoryPolicy(in: database)
            let generation = current.isEnabled && !isEnabled ? current.generation + 1 : current.generation
            try database.execute(
                sql: """
                    UPDATE dictationHistoryPolicy
                    SET isEnabled = ?, keepsOriginal = ?, retentionDays = ?, generation = ?
                    WHERE id = 1
                    """,
                arguments: [isEnabled, keepsOriginal, retentionDays, generation])
            try Self.purgeExpiredDictations(in: database, retentionDays: retentionDays, now: now)
            return try Self.dictationHistoryPolicy(in: database)
        }
    }

    /// Saves one dictation, or updates the delivery of the same dictation after
    /// a retry. Consent is revalidated in the write transaction.
    public func recordDictation(
        _ record: DictationRecord, admittedGeneration: Int, at now: Date = Date()
    ) async throws -> DictationRecordOutcome {
        guard record.isValid else { throw StorageError.invalidDictationRecord("invalid input") }
        return try await database.write { database in
            let policy = try Self.dictationHistoryPolicy(in: database)
            guard policy.isEnabled, policy.generation == admittedGeneration else { return .refused }
            try database.execute(
                sql: """
                    INSERT INTO dictationRecord (
                        id, createdAt, durationMs, text, originalText, mode, language,
                        engine, applicationName, applicationBundleID, delivery
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET delivery = excluded.delivery
                    """,
                arguments: [
                    record.id.rawValue.uuidString,
                    record.createdAt,
                    Int((record.duration * 1_000).rounded()),
                    record.text,
                    policy.keepsOriginal ? record.originalText : nil,
                    record.mode.rawValue,
                    record.language,
                    record.engine,
                    record.applicationName,
                    record.applicationBundleID,
                    record.delivery.rawValue
                ])
            try Self.purgeExpiredDictations(in: database, retentionDays: policy.retentionDays, now: now)
            return .saved
        }
    }

    /// Newest first, with every filter applied before the limit. `before`
    /// continues after the last row of the previous page.
    public func dictationRecords(
        matching filter: DictationRecordFilter = .all, before cursor: DictationRecord? = nil, limit: Int
    ) async throws -> [DictationRecord] {
        guard (1...Self.maximumDictationPageSize).contains(limit) else { return [] }
        let match = Self.dictationSearchQuery(filter.query)
        if !filter.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, match == nil { return [] }
        var conditions: [String] = []
        var arguments = StatementArguments()
        if let match {
            conditions.append("""
                dictationRecord.rowid IN (
                    SELECT rowid FROM dictationRecordSearch WHERE dictationRecordSearch MATCH ?)
                """)
            arguments += [match]
        }
        if let application = filter.applicationName {
            conditions.append("applicationName = ?")
            arguments += [application]
        }
        if filter.onlyNotDelivered {
            conditions.append("delivery = ?")
            arguments += [DictationRecordDelivery.notDelivered.rawValue]
        }
        if let cursor {
            conditions.append("(createdAt < ? OR (createdAt = ? AND id < ?))")
            arguments += [cursor.createdAt, cursor.createdAt, cursor.id.rawValue.uuidString]
        }
        arguments += [limit]
        let filters = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
            SELECT id, createdAt, durationMs, text, originalText, mode, language,
                   engine, applicationName, applicationBundleID, delivery
            FROM dictationRecord
            \(filters)
            ORDER BY createdAt DESC, id DESC LIMIT ?
            """
        return try await database.read { [arguments] database in
            try Row.fetchAll(database, sql: sql, arguments: arguments).map(Self.dictationRecord(from:))
        }
    }

    /// Applications with at least one saved dictation, for the filter menu.
    public func dictationApplications() async throws -> [String] {
        try await database.read { database in
            try String.fetchAll(database, sql: """
                SELECT DISTINCT applicationName FROM dictationRecord
                WHERE applicationName IS NOT NULL ORDER BY applicationName COLLATE NOCASE
                """)
        }
    }

    /// Every word must appear and the last one may be unfinished. Words are
    /// quoted, so FTS5 syntax typed by the user is matched as text, never run.
    static func dictationSearchQuery(_ text: String) -> String? {
        let terms = text.prefix(DictationRecordFilter.maximumQueryLength)
            .split(whereSeparator: \.isWhitespace)
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
            .prefix(DictationRecordFilter.maximumQueryTerms)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        guard let last = terms.last else { return nil }
        return (terms.dropLast() + [last + "*"]).joined(separator: " ")
    }

    public func deleteDictationRecord(_ id: DictationRecordID) async throws -> Bool {
        try await database.write { database in
            try database.execute(
                sql: "DELETE FROM dictationRecord WHERE id = ?", arguments: [id.rawValue.uuidString])
            return database.changesCount == 1
        }
    }

    /// Also advances the generation, so no dictation still in flight repopulates it.
    @discardableResult
    public func deleteAllDictationRecords() async throws -> Int {
        try await database.write { database in
            try database.execute(sql: "DELETE FROM dictationRecord")
            let deleted = database.changesCount
            try database.execute(sql: "UPDATE dictationHistoryPolicy SET generation = generation + 1 WHERE id = 1")
            return deleted
        }
    }

    @discardableResult
    public func purgeExpiredDictationRecords(at now: Date = Date()) async throws -> Int {
        try await database.write { database in
            let policy = try Self.dictationHistoryPolicy(in: database)
            return try Self.purgeExpiredDictations(in: database, retentionDays: policy.retentionDays, now: now)
        }
    }

    @discardableResult
    private static func purgeExpiredDictations(in database: Database, retentionDays: Int, now: Date) throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        try database.execute(sql: "DELETE FROM dictationRecord WHERE createdAt < ?", arguments: [cutoff])
        return database.changesCount
    }

    private static func dictationHistoryPolicy(in database: Database) throws -> DictationHistoryPolicy {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT isEnabled, keepsOriginal, retentionDays, generation FROM dictationHistoryPolicy WHERE id = 1")
        else { return .off }
        return DictationHistoryPolicy(
            isEnabled: row["isEnabled"], keepsOriginal: row["keepsOriginal"],
            retentionDays: row["retentionDays"], generation: row["generation"])
    }

    private static func dictationRecord(from row: Row) throws -> DictationRecord {
        let rawID: String = row["id"]
        guard let uuid = UUID(uuidString: rawID) else {
            throw StorageError.invalidPersistedUUID(table: "dictationRecord", column: "id", value: rawID)
        }
        let rawMode: String = row["mode"]
        let rawDelivery: String = row["delivery"]
        guard let mode = DictationTextMode(rawValue: rawMode) else {
            throw StorageError.invalidPersistedValue(table: "dictationRecord", column: "mode", value: rawMode)
        }
        guard let delivery = DictationRecordDelivery(rawValue: rawDelivery) else {
            throw StorageError.invalidPersistedValue(
                table: "dictationRecord", column: "delivery", value: rawDelivery)
        }
        let durationMs: Int = row["durationMs"]
        return DictationRecord(
            id: DictationRecordID(rawValue: uuid),
            createdAt: row["createdAt"],
            duration: Double(durationMs) / 1_000,
            text: row["text"],
            originalText: row["originalText"],
            mode: mode,
            language: row["language"],
            engine: row["engine"],
            applicationName: row["applicationName"],
            applicationBundleID: row["applicationBundleID"],
            delivery: delivery)
    }
}
