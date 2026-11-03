import Foundation
import PortavozCore
import StorageKit
import XCTest

@testable import portavoz_app

final class DictationStatsTests: XCTestCase {
    func testWordsDaysAndTimeSavedAreCountedPlainly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(DictationStatsCalendar.wordCount("Send the report — on Friday, ¿vale?"), 6)
        XCTAssertEqual(DictationStatsCalendar.wordCount("  "), 0)
        XCTAssertEqual(DictationStatsCalendar.days(endingAt: now, count: 3, calendar: calendar),
                       ["2027-01-13", "2027-01-14", "2027-01-15"])
        XCTAssertEqual(
            DictationStatsTotals(dictations: 1, words: 80, spokenDuration: 30, notDelivered: 0).estimatedTimeSaved, 90)
        XCTAssertEqual(
            DictationStatsTotals(dictations: 1, words: 10, spokenDuration: 60, notDelivered: 0).estimatedTimeSaved, 0)
    }

    @MainActor
    func testADeliveryIsCountedOnceWithoutTextAndSecureFieldsAreNot() async {
        let controller = DictationController(presentsPanel: false)
        var samples: [DictationStatsSample] = []
        let id = UUID()
        controller.statsDraft = DictationStatsDraft(
            sessionID: id, startedAt: Date(timeIntervalSince1970: 1_800_000_000), spokenDuration: 3, words: 5,
            applicationName: "Slack", record: { samples.append($0) })

        controller.recordStats(.refused(.secureField), id: id)
        controller.recordStats(.verified, id: UUID())
        controller.recordStats(.verified, id: id)

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.id, DictationRecordID(rawValue: id))
        XCTAssertEqual(samples.first?.words, 5)
        XCTAssertEqual(samples.first?.applicationName, "Slack")
        XCTAssertEqual(samples.first?.delivered, true)
    }

    @MainActor
    func testTheModelFollowsConsentRangeAndDeletion() async throws {
        let store = try MeetingStore.inMemory()
        let model = DictationStatsModel(store: store)
        await model.load()
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.summary.days.count, 7)

        await model.update(isEnabled: true)
        try await store.recordDictationStats(DictationStatsSample(
            id: DictationRecordID(), day: DictationStatsCalendar.day(of: Date(), calendar: .current),
            words: 9, spokenDuration: 2, applicationName: "Mail", delivered: true))
        await model.show(range: 30)
        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(model.summary.days.count, 30)
        XCTAssertEqual(model.summary.totals.words, 9)

        await model.deleteAll()
        XCTAssertEqual(model.summary.totals, .zero)
        XCTAssertNil(model.failure)
    }
}
