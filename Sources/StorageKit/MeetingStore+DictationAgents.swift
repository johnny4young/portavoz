import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// A page for a local agent. Agent consent is read in the same transaction
    /// as the rows, so a revoked consent never returns content.
    public func dictationRecordsForAgents(
        matching filter: DictationRecordFilter, offset: Int, limit: Int
    ) async throws -> DictationAgentRead<DictationRecordPage> {
        let start = max(0, offset)
        let size = min(max(1, limit), Self.maximumDictationPageSize)
        let filtered = Self.dictationFilterConditions(filter)
        return try await database.read { database in
            guard try Self.dictationHistoryPolicy(in: database).agentsCanRead else { return .notAllowed }
            guard let (conditions, arguments) = filtered else {
                return .allowed(DictationRecordPage(total: 0, offset: start, records: []))
            }
            let filters = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let total = try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM dictationRecord \(filters)", arguments: arguments) ?? 0
            var pageArguments = arguments
            pageArguments += [size, start]
            let records = try Row.fetchAll(
                database,
                sql: Self.dictationColumns + "\n\(filters)\nORDER BY createdAt DESC, id DESC LIMIT ? OFFSET ?",
                arguments: pageArguments
            ).map(Self.dictationRecord(from:))
            return .allowed(DictationRecordPage(total: total, offset: start, records: records))
        }
    }

    public func dictationRecordForAgents(
        _ id: DictationRecordID
    ) async throws -> DictationAgentRead<DictationRecord?> {
        try await database.read { database in
            guard try Self.dictationHistoryPolicy(in: database).agentsCanRead else { return .notAllowed }
            let row = try Row.fetchOne(
                database, sql: Self.dictationColumns + "\nWHERE id = ?", arguments: [id.rawValue.uuidString])
            return .allowed(try row.map(Self.dictationRecord(from:)))
        }
    }
}
