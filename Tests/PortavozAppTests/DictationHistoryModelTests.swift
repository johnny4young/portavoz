import PortavozCore
import StorageKit
import XCTest

@testable import portavoz_app

@MainActor
final class DictationHistoryModelTests: XCTestCase {
    func testAFilteredListOnlyShowsMatchingDictationsWhileTheMenuLearnsNewApps() async throws {
        let model = DictationHistoryModel(store: try MeetingStore.inMemory())
        await model.load()
        await model.update(isEnabled: true)
        let write = try XCTUnwrap(model.admit())
        _ = await write(record("Send the report on Friday.", app: "Slack"))
        _ = await write(record("No borres estas notas.", app: "Notes"))

        await model.apply(.init(applicationName: "Slack"))
        XCTAssertEqual(model.records.map(\.text), ["Send the report on Friday."])

        _ = await write(record("Reply to the thread.", app: "Mail"))
        XCTAssertEqual(model.records.map(\.text), ["Send the report on Friday."], "A new row must match the filter")
        XCTAssertEqual(model.applications, ["Mail", "Notes", "Slack"])

        await model.apply(.init(query: "notas"))
        XCTAssertEqual(model.records.map(\.text), ["No borres estas notas."])
        await model.apply(.all)
        XCTAssertEqual(model.records.count, 3)

        await model.deleteAll()
        XCTAssertEqual(model.filter, .all)
        XCTAssertEqual(model.applications, [])
    }

    private func record(_ text: String, app: String) -> DictationRecord {
        DictationRecord(
            id: DictationRecordID(), createdAt: Date(), duration: 1, text: text, originalText: nil,
            mode: .literal, language: nil, engine: "parakeet", applicationName: app,
            applicationBundleID: nil, delivery: .verified)
    }
}
