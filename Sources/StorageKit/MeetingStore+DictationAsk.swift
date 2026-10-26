import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    public static let maximumDictationAskTerms = 48

    /// Retrieval for Ask. Words rank any-word FTS matches; without usable words
    /// the newest dictations answer. The period and app filter both before the
    /// limit. Consent is read in the same transaction as the rows; nil means
    /// the history is off and nothing was read.
    public func dictationRecordsForAsk(
        matchingAny queries: [String], period: DateInterval? = nil, applicationName: String? = nil, limit: Int
    ) async throws -> [DictationRecord]? {
        let size = min(max(1, limit), Self.maximumDictationPageSize)
        let match = Self.dictationAskQuery(queries)
        var conditions: [String] = []
        var arguments = StatementArguments()
        if let match {
            conditions.append("dictationRecordSearch MATCH ?")
            arguments += [match]
        }
        if let period {
            conditions.append("dictationRecord.createdAt >= ? AND dictationRecord.createdAt < ?")
            arguments += [period.start, period.end]
        }
        if let applicationName {
            conditions.append("dictationRecord.applicationName = ?")
            arguments += [applicationName]
        }
        arguments += [size]
        let source = match == nil
            ? "FROM dictationRecord"
            : "FROM dictationRecordSearch JOIN dictationRecord ON dictationRecord.rowid = dictationRecordSearch.rowid"
        let order = match == nil ? "" : "rank, "
        let filters = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
            SELECT dictationRecord.id, dictationRecord.createdAt, durationMs, dictationRecord.text,
                   dictationRecord.originalText, mode, language, engine,
                   dictationRecord.applicationName, applicationBundleID, delivery
            \(source)
            \(filters)
            ORDER BY \(order)dictationRecord.createdAt DESC, dictationRecord.id DESC
            LIMIT ?
            """
        return try await database.read { [arguments] database in
            guard try Self.dictationHistoryPolicy(in: database).isEnabled else { return nil }
            return try Row.fetchAll(database, sql: sql, arguments: arguments).map(Self.dictationRecord(from:))
        }
    }

    /// App names with saved dictations, so Ask can recognize "in Slack"; nil while the history is off.
    public func dictationApplicationsForAsk() async throws -> [String]? {
        try await database.read { database in
            guard try Self.dictationHistoryPolicy(in: database).isEnabled else { return nil }
            return try String.fetchAll(database, sql: """
                SELECT DISTINCT applicationName FROM dictationRecord WHERE applicationName IS NOT NULL
                """)
        }
    }

    /// Any word may match; repeated words across query variants count once.
    /// Words are quoted, so FTS5 syntax in a question is matched as text.
    static func dictationAskQuery(_ queries: [String]) -> String? {
        var seen = Set<String>()
        let terms = queries
            .flatMap { $0.prefix(DictationRecordFilter.maximumQueryLength).split(whereSeparator: \.isWhitespace) }
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
            .map { $0.lowercased() }
            .filter { seen.insert($0).inserted }
            .prefix(maximumDictationAskTerms)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        return terms.isEmpty ? nil : terms.joined(separator: " OR ")
    }
}
