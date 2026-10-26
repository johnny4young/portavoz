import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class DictationStatsStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testNothingIsCountedUntilStatisticsAreTurnedOnEvenWithTheHistoryOn() async throws {
        let store = try MeetingStore.inMemory()
        _ = try await store.setDictationHistoryPolicy(isEnabled: true, keepsOriginal: false, retentionDays: 30, at: now)

        let counted = try await store.recordDictationStats(sample(), at: now, calendar: calendar)
        let enabled = try await store.dictationStatsEnabled()
        let summary = try await store.dictationStatsSummary(days: [today])

        XCTAssertFalse(enabled)
        XCTAssertFalse(counted)
        XCTAssertEqual(summary.totals, .zero)
    }

    func testDaysAndAppsAddUpWithEmptyDaysFilledAndTheBusiestAppsFirst() async throws {
        let store = try await enabledStore()
        for (app, words) in [("Slack", 10), ("Slack", 20), ("Mail", 5), (nil, 7)] {
            try await store.recordDictationStats(sample(words: words, app: app), at: now, calendar: calendar)
        }
        try await store.recordDictationStats(sample(day: yesterday, words: 3, app: "Notes"), at: now, calendar: calendar)
        for index in 0..<6 {
            try await store.recordDictationStats(sample(words: 1, app: "App \(index)"), at: now, calendar: calendar)
        }

        let days = DictationStatsCalendar.days(endingAt: now, count: 3, calendar: calendar)
        let summary = try await store.dictationStatsSummary(days: days)

        XCTAssertEqual(summary.days.map(\.day), days)
        XCTAssertEqual(summary.days[0].totals, .zero, "an empty day is still listed")
        XCTAssertEqual(summary.days[2].totals.dictations, 10)
        XCTAssertEqual(summary.days[2].totals.words, 48)
        XCTAssertEqual(summary.totals.dictations, 11)
        XCTAssertEqual(summary.topApplications.count, DictationStatsCalendar.topApplicationCount)
        XCTAssertEqual(summary.topApplications.first, DictationStatsApplication(name: "Slack", dictations: 2, words: 30))
        XCTAssertFalse(summary.topApplications.contains { $0.name.isEmpty }, "an unknown app is not ranked")
    }

    func testARetryMovesOneDictationBetweenNotDeliveredAndDeliveredWithoutCountingAgain() async throws {
        let store = try await enabledStore()
        let id = DictationRecordID()
        try await store.recordDictationStats(sample(id: id, delivered: false), at: now, calendar: calendar)
        try await store.recordDictationStats(sample(id: id, delivered: false), at: now, calendar: calendar)
        let failed = try await store.dictationStatsSummary(days: [today]).totals
        try await store.recordDictationStats(sample(id: id, delivered: true), at: now, calendar: calendar)
        let recovered = try await store.dictationStatsSummary(days: [today]).totals

        XCTAssertEqual(failed.dictations, 1)
        XCTAssertEqual(failed.notDelivered, 1)
        XCTAssertEqual(recovered.dictations, 1)
        XCTAssertEqual(recovered.notDelivered, 0)
    }

    func testOldDaysAndCountedIdentitiesArePurgedAndTurningOffKeepsTotalsUntilDeleted() async throws {
        let store = try await enabledStore()
        let old = DictationStatsCalendar.day(of: now.addingTimeInterval(-400 * 86_400), calendar: calendar)
        try await store.recordDictationStats(sample(day: old), at: now.addingTimeInterval(-400 * 86_400), calendar: calendar)
        try await store.recordDictationStats(sample(), at: now, calendar: calendar)
        let ledger = try await store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM dictationStatsCounted") }
        let oldDays = try await store.dictationStatsSummary(days: [old]).totals

        XCTAssertEqual(oldDays, .zero, "a day older than a year is purged")
        XCTAssertEqual(ledger, 1, "identities older than two days are forgotten")

        try await store.setDictationStatsEnabled(false)
        let counted = try await store.recordDictationStats(sample(), at: now, calendar: calendar)
        let kept = try await store.dictationStatsSummary(days: [today]).totals
        try await store.deleteDictationStats()
        let deleted = try await store.dictationStatsSummary(days: [today]).totals

        XCTAssertFalse(counted)
        XCTAssertEqual(kept.dictations, 1)
        XCTAssertEqual(deleted, .zero)
    }

    func testInvalidSamplesAreRefused() async throws {
        let store = try await enabledStore()
        let invalid = [
            sample(day: "2026-1-1"), sample(words: -1),
            sample(app: String(repeating: "a", count: DictationRecord.maximumLabelLength + 1))
        ]
        for value in invalid {
            do {
                try await store.recordDictationStats(value, at: now, calendar: calendar)
                XCTFail("an invalid sample must be refused")
            } catch {}
        }
    }

    func testV58StartsWithStatisticsOff() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-stats-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try DatabaseQueue(path: url.path)
        try StorageSchema.migrator().migrate(database, upTo: "v57")
        try database.close()

        let store = try MeetingStore(databaseURL: url)
        let enabled = try await store.dictationStatsEnabled()
        XCTAssertFalse(enabled)
        XCTAssertGreaterThanOrEqual(StorageSchema.version, 58)
    }

    private var today: String { DictationStatsCalendar.day(of: now, calendar: calendar) }
    private var yesterday: String { DictationStatsCalendar.day(of: now.addingTimeInterval(-86_400), calendar: calendar) }

    private func enabledStore() async throws -> MeetingStore {
        let store = try MeetingStore.inMemory()
        try await store.setDictationStatsEnabled(true)
        return store
    }

    private func sample(
        id: DictationRecordID = DictationRecordID(), day: String? = nil, words: Int = 12,
        app: String? = "Slack", delivered: Bool = true
    ) -> DictationStatsSample {
        DictationStatsSample(
            id: id, day: day ?? today, words: words, spokenDuration: 4, applicationName: app, delivered: delivered)
    }
}
