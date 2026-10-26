import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class DictationAgentAccessStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testV56AddsAgentAccessOffWithoutChangingTheHistoryConsent() throws {
        let database = try DatabaseQueue()
        try StorageSchema.migrator().migrate(database, upTo: "v55")
        try database.write { try $0.execute(sql: "UPDATE dictationHistoryPolicy SET isEnabled = 1 WHERE id = 1") }
        try StorageSchema.migrator().migrate(database, upTo: "v56")
        try database.read { database in
            let row = try XCTUnwrap(try Row.fetchOne(database, sql: "SELECT * FROM dictationHistoryPolicy"))
            XCTAssertEqual(row["isEnabled"], true)
            XCTAssertEqual(row["exposesToAgents"], false)
        }
    }

    func testAgentsReadOnlyWhileBothHistoryAndSharingAreOn() async throws {
        let store = try MeetingStore.inMemory()
        let generation = try await store.setDictationHistoryPolicy(
            isEnabled: true, keepsOriginal: false, retentionDays: 30, at: now).generation
        _ = try await store.recordDictation(record(), admittedGeneration: generation, at: now)

        let notShared = try await store.dictationRecordsForAgents(matching: .all, offset: 0, limit: 10)
        let shared = try await enableSharing(store)
        let page = try await store.dictationRecordsForAgents(matching: .all, offset: 0, limit: 10)
        _ = try await store.setDictationHistoryPolicy(
            isEnabled: false, keepsOriginal: false, retentionDays: 30, exposesToAgents: true, at: now)
        let historyOff = try await store.dictationRecordsForAgents(matching: .all, offset: 0, limit: 10)
        let reenabled = try await store.setDictationHistoryPolicy(
            isEnabled: true, keepsOriginal: false, retentionDays: 30, at: now)

        XCTAssertEqual(notShared, .notAllowed)
        XCTAssertTrue(shared.agentsCanRead)
        guard case .allowed(let allowed) = page else { return XCTFail("sharing on must read") }
        XCTAssertEqual(allowed.total, 1)
        XCTAssertEqual(historyOff, .notAllowed, "history off with a stale sharing flag still reads nothing")
        XCTAssertFalse(reenabled.exposesToAgents, "turning history back on does not re-share it")
    }

    func testOffsetPagesCountTheFilteredTotal() async throws {
        let store = try MeetingStore.inMemory()
        let generation = try await enableSharing(store).generation
        for index in 0..<5 {
            _ = try await store.recordDictation(
                record(text: index.isMultiple(of: 2) ? "Nota par \(index)" : "Odd \(index)",
                       createdAt: now.addingTimeInterval(Double(-index))),
                admittedGeneration: generation, at: now)
        }
        let first = try await store.dictationRecordsForAgents(matching: .init(query: "nota"), offset: 0, limit: 2)
        let second = try await store.dictationRecordsForAgents(matching: .init(query: "nota"), offset: 2, limit: 2)
        let negative = try await store.dictationRecordsForAgents(matching: .all, offset: -3, limit: 0)

        guard case .allowed(let a) = first, case .allowed(let b) = second, case .allowed(let c) = negative
        else { return XCTFail("sharing is on") }
        XCTAssertEqual(a.total, 3)
        XCTAssertEqual(a.records.map(\.text) + b.records.map(\.text), ["Nota par 0", "Nota par 2", "Nota par 4"])
        XCTAssertEqual(c.offset, 0)
        XCTAssertEqual(c.records.count, 1, "a zero limit still reads one row")
    }

    func testOneDictationIsReadOnlyWithSharingOn() async throws {
        let store = try MeetingStore.inMemory()
        let generation = try await store.setDictationHistoryPolicy(
            isEnabled: true, keepsOriginal: false, retentionDays: 30, at: now).generation
        let dictation = record()
        _ = try await store.recordDictation(dictation, admittedGeneration: generation, at: now)

        let refused = try await store.dictationRecordForAgents(dictation.id)
        _ = try await enableSharing(store)
        let found = try await store.dictationRecordForAgents(dictation.id)
        let missing = try await store.dictationRecordForAgents(DictationRecordID())

        XCTAssertEqual(refused, .notAllowed)
        XCTAssertEqual(found, .allowed(dictation))
        XCTAssertEqual(missing, .allowed(nil))
    }

    @discardableResult
    private func enableSharing(_ store: MeetingStore) async throws -> DictationHistoryPolicy {
        try await store.setDictationHistoryPolicy(
            isEnabled: true, keepsOriginal: false, retentionDays: 30, exposesToAgents: true, at: now)
    }

    private func record(text: String = "No borres estas notas.", createdAt: Date? = nil) -> DictationRecord {
        DictationRecord(
            id: DictationRecordID(), createdAt: createdAt ?? now, duration: 2, text: text, originalText: nil,
            mode: .literal, language: nil, engine: "parakeet", applicationName: "Notes",
            applicationBundleID: nil, delivery: .verified)
    }
}
