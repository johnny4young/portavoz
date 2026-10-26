import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class DictationSearchStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testV55IndexesDictationsSavedBeforeTheMigration() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-search-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try DatabaseQueue(path: url.path)
        try StorageSchema.migrator().migrate(database, upTo: "v54")
        let createdAt = now
        try await database.write { database in
            try database.execute(sql: "UPDATE dictationHistoryPolicy SET isEnabled = 1 WHERE id = 1")
            try database.execute(sql: """
                INSERT INTO dictationRecord (id, createdAt, durationMs, text, mode, engine, delivery)
                VALUES (?, ?, 1000, 'Revisa la acción pendiente', 'literal', 'parakeet', 'verified')
                """, arguments: [UUID().uuidString, createdAt])
        }
        try database.close()

        let store = try MeetingStore(databaseURL: url)
        let hits = try await store.dictationRecords(matching: .init(query: "accion"), limit: 10)
        XCTAssertEqual(hits.map(\.text), ["Revisa la acción pendiente"])
    }

    func testSearchIgnoresAccentsAndCaseCoversTheOriginalAndCompletesTheLastWord() async throws {
        let store = try await populatedStore()
        let accent = try await texts(store, "ACCION")
        let original = try await texts(store, "eh")
        let prefix = try await texts(store, "repor")
        let allWords = try await texts(store, "report notas")
        let earlierWordIsWhole = try await texts(store, "rep friday")

        XCTAssertEqual(accent, ["Revisa la acción pendiente."])
        XCTAssertEqual(original, ["No borres estas notas."])
        XCTAssertEqual(prefix, ["Send the report on Friday."])
        XCTAssertEqual(allWords, [])
        XCTAssertEqual(earlierWordIsWhole, [])
    }

    func testDeletedPurgedAndClearedDictationsLeaveTheIndex() async throws {
        let store = try await populatedStore()
        let report = try await store.dictationRecords(matching: .init(query: "report"), limit: 10)
        _ = try await store.deleteDictationRecord(try XCTUnwrap(report.first).id)
        let afterDelete = try await texts(store, "report")

        _ = try await store.purgeExpiredDictationRecords(at: now.addingTimeInterval(31 * 86_400))
        let afterPurge = try await texts(store, "notas")
        let rowsInIndex = try await indexRowCount(store)

        XCTAssertEqual(afterDelete, [])
        XCTAssertEqual(afterPurge, [])
        XCTAssertEqual(rowsInIndex, 0)
    }

    func testFiltersApplyBeforeTheLimitAndPagesStayStable() async throws {
        let store = try MeetingStore.inMemory()
        _ = try await store.setDictationHistoryPolicy(isEnabled: true, keepsOriginal: false, retentionDays: 30, at: now)
        for index in 0..<6 {
            let slack = index < 3
            _ = try await store.recordDictation(
                record(
                    text: slack ? "Slack note \(index)" : "Mail note \(index)",
                    app: slack ? "Slack" : "Mail",
                    delivery: index == 1 ? .notDelivered : .verified,
                    createdAt: index < 2 ? now : now.addingTimeInterval(Double(index))),
                admittedGeneration: 0, at: now)
        }
        let slackFirst = try await store.dictationRecords(matching: .init(applicationName: "Slack"), limit: 2)
        let slackNext = try await store.dictationRecords(
            matching: .init(applicationName: "Slack"), before: slackFirst.last, limit: 2)
        let searched = try await store.dictationRecords(matching: .init(query: "note", applicationName: "Mail"), limit: 10)
        let undelivered = try await store.dictationRecords(matching: .init(onlyNotDelivered: true), limit: 10)
        let applications = try await store.dictationApplications()

        XCTAssertEqual(Set((slackFirst + slackNext).map(\.text)), ["Slack note 0", "Slack note 1", "Slack note 2"])
        XCTAssertEqual(slackFirst.count + slackNext.count, 3)
        XCTAssertEqual(searched.map(\.applicationName), ["Mail", "Mail", "Mail"])
        XCTAssertEqual(undelivered.map(\.text), ["Slack note 1"])
        XCTAssertEqual(applications, ["Mail", "Slack"])
    }

    func testTypedSearchSyntaxIsMatchedAsTextNeverRun() async throws {
        let store = try await populatedStore()
        let hostile = [
            "\"", "*", "-", ":", "()", "NEAR(report friday)", "text:report", "report OR notas", "^report",
            "report\"", "🙂", "acción\u{301}", String(repeating: "a ", count: 500), "'; DROP TABLE dictationRecord;--"
        ]
        for query in hostile {
            _ = try await store.dictationRecords(matching: .init(query: query), limit: 10)
        }
        let orIsAWord = try await texts(store, "report OR notas")
        let columnSyntax = try await texts(store, "text:report")
        let stillThere = try await store.dictationRecords(limit: 10).count

        XCTAssertEqual(orIsAWord, [])
        XCTAssertEqual(columnSyntax, [])
        XCTAssertEqual(stillThere, 3)
    }

    func testTheQueryKeepsOnlyBoundedQuotedWords() {
        XCTAssertNil(MeetingStore.dictationSearchQuery("  🙂 -- "))
        XCTAssertEqual(MeetingStore.dictationSearchQuery("send \"rep"), "\"send\" \"\"\"rep\"*")
        let many = (1...40).map { "w\($0)" }.joined(separator: " ")
        let words = MeetingStore.dictationSearchQuery(many)?.split(separator: " ")
        XCTAssertEqual(words?.count, DictationRecordFilter.maximumQueryTerms)
    }

    private func populatedStore() async throws -> MeetingStore {
        let store = try MeetingStore.inMemory()
        _ = try await store.setDictationHistoryPolicy(isEnabled: true, keepsOriginal: true, retentionDays: 30, at: now)
        let samples: [(String, String?, String)] = [
            ("No borres estas notas.", "eh no borres estas notas", "Notes"),
            ("Send the report on Friday.", nil, "Slack"),
            ("Revisa la acción pendiente.", nil, "Mail")
        ]
        for (offset, sample) in samples.enumerated() {
            _ = try await store.recordDictation(
                record(text: sample.0, original: sample.1, app: sample.2,
                       createdAt: now.addingTimeInterval(Double(-offset))),
                admittedGeneration: 0, at: now)
        }
        return store
    }

    private func texts(_ store: MeetingStore, _ query: String) async throws -> [String] {
        try await store.dictationRecords(matching: .init(query: query), limit: 10).map(\.text)
    }

    private func indexRowCount(_ store: MeetingStore) async throws -> Int {
        try await store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM dictationRecordSearch") ?? -1 }
    }

    private func record(
        text: String, original: String? = nil, app: String, delivery: DictationRecordDelivery = .verified,
        createdAt: Date
    ) -> DictationRecord {
        DictationRecord(
            id: DictationRecordID(), createdAt: createdAt, duration: 1, text: text, originalText: original,
            mode: .clean, language: nil, engine: "parakeet", applicationName: app, applicationBundleID: nil,
            delivery: delivery)
    }
}
