import AppKit
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class DictationHistoryRecordingTests: XCTestCase {
    func testAVerifiedDictationIsSavedWithItsDestinationAndThePanelSaysSo() async throws {
        let (controller, services) = try makeServices()
        await services.dictationHistory.load()
        await services.dictationHistory.update(isEnabled: true)

        try await dictate(controller, using: services.makeDictationSessionDependencies())
        let saved = await eventually { services.dictationHistory.records.count == 1 }

        XCTAssertTrue(saved)
        let record = try XCTUnwrap(services.dictationHistory.records.first)
        XCTAssertEqual(record.text, "No borres estas notas.")
        XCTAssertEqual(record.delivery, .verified)
        XCTAssertEqual(record.applicationName, "Dictation test receiver")
        XCTAssertFalse(record.engine.isEmpty)
        XCTAssertEqual(controller.deliveryPrivacyLine, L10n.text("Saved to your dictation history."))
        controller.cancel()
    }

    func testNothingIsSavedWhenHistoryIsOffOrTheSessionIsPractice() async throws {
        let (controller, services) = try makeServices()
        await services.dictationHistory.load()
        try await dictate(controller, using: services.makeDictationSessionDependencies())
        XCTAssertEqual(controller.deliveryPrivacyLine, L10n.text("Nothing was saved in Portavoz."))

        await services.dictationHistory.update(isEnabled: true)
        let holder = UUID()
        services.dictationPractice.show(holder, isKey: true)
        defer { services.dictationPractice.hide(holder) }
        let practice = services.dictationPractice.route(services.makeDictationSessionDependencies(), appIsActive: true)
        try await dictate(controller, using: practice)

        await services.dictationHistory.load()
        XCTAssertEqual(services.dictationHistory.records, [])
        controller.cancel()
    }

    func testDeletingEverythingWhileADictationFinishesKeepsItOut() async throws {
        let (_, services) = try makeServices()
        let history = services.dictationHistory
        await history.load()
        await history.update(isEnabled: true)
        let writer = try XCTUnwrap(history.admit())

        await history.deleteAll()
        let completed = await writer(record())
        await history.load()

        XCTAssertTrue(completed, "A refused write is consent working, not a failure")
        XCTAssertEqual(history.records, [])
        XCTAssertNotNil(history.admit(), "History stays on after deleting its contents")
    }

    func testSecureCancelledAndEmptyDeliveriesAreNeverSaved() async {
        XCTAssertNil(DictationHistorySession.delivery(for: .refused(.secureField)))
        XCTAssertNil(DictationHistorySession.delivery(for: .refused(.cancelled)))
        XCTAssertNil(DictationHistorySession.delivery(for: .refused(.emptyText)))
        XCTAssertEqual(DictationHistorySession.delivery(for: .refused(.targetChanged)), .notDelivered)
        XCTAssertEqual(DictationHistorySession.delivery(for: .dispatched), .dispatched)
        XCTAssertEqual(DictationHistorySession.delivery(for: .verified), .verified)
    }

    private func makeServices() throws -> (DictationController, AppServices) {
        let controller = DictationController(presentsPanel: false)
        let services = try AppServices(
            arguments: ["-use-temp-store", "-seed-dictation", "-seed-dictation-delivery", "-seed-dictation-verified"],
            environment: [:], dictation: controller)
        return (controller, services)
    }

    private func dictate(_ controller: DictationController, using dependencies: DictationSessionDependencies)
        async throws {
        controller.toggle(using: dependencies)
        let listening = await eventually { controller.partialText == "No borres estas notas." }
        XCTAssertTrue(listening)
        controller.toggle(using: dependencies)
        let delivered = await eventually { controller.phase == .verified(4) }
        XCTAssertTrue(delivered)
        _ = await eventually { controller.history?.state != .saving }
    }

    private func record() -> DictationRecord {
        DictationRecord(
            id: DictationRecordID(), createdAt: Date(), duration: 1, text: "Hola", originalText: nil,
            mode: .literal, language: nil, engine: "parakeet", applicationName: nil,
            applicationBundleID: nil, delivery: .verified)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
