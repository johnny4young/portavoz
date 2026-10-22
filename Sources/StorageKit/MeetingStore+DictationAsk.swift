import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    public static let maximumDictationAskTerms = 48

    /// Ranked any-word retrieval for Ask. The history consent is read in the
    /// same transaction as the rows; nil means the history is off and nothing
    /// was read.
    public func dictationRecordsForAsk(
        matchingAny queries: [String], limit: Int
    ) async throws -> [DictationRecord]? {
        let size = min(max(1, limit), Self.maximumDictationPageSize)
        let match = Self.dictationAskQuery(queries)
        return try await database.read { database in
            guard try Self.dictationHistoryPolicy(in: database).isEnabled else { return nil }
            guard let match else { return [] }
            return try Row.fetchAll(
                database,
                sql: """
                    SELECT dictationRecord.id, createdAt, durationMs, dictationRecord.text,
                           dictationRecord.originalText, mode, language, engine,
                           applicationName, applicationBundleID, delivery
                    FROM dictationRecordSearch
                    JOIN dictationRecord ON dictationRecord.rowid = dictationRecordSearch.rowid
                    WHERE dictationRecordSearch MATCH ?
                    ORDER BY rank, createdAt DESC, dictationRecord.id DESC
                    LIMIT ?
                    """,
                arguments: [match, size]
            ).map(Self.dictationRecord(from:))
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
