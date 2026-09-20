import ApplicationKit
import Foundation
import XCTest

@testable import portavoz_app

@MainActor
final class SettingsTransferModelTests: XCTestCase {
    func testReviewCancelAndApplyReachRealDefaultsOnlyAfterApproval() async throws {
        let client = try SettingsTransferTestClient()
        let before = try client.portableSettingsSnapshot()
        let model = SettingsTransferModel()
        await model.importFile(using: client)
        XCTAssertNotNil(model.review)
        XCTAssertEqual(try client.portableSettingsSnapshot(), before)
        model.cancelReview()
        model.apply(using: client)
        XCTAssertEqual(client.applied, 0)
        await model.importFile(using: client)
        model.apply(using: client)
        XCTAssertNil(model.review)
        XCTAssertEqual(client.applied, 1)
        XCTAssertEqual(try client.portableSettingsSnapshot()[.vocabulary], .text("Cóndor, Don’t, C++"))
        model.apply(using: client)
        XCTAssertEqual(client.applied, 1, "a delivered Apply cannot replay")
    }

    func testCaptureAndConcurrentPreferencesRejectAtActualApply() async throws {
        let client = try SettingsTransferTestClient()
        let model = SettingsTransferModel()
        await model.importFile(using: client)
        client.captureActive = true
        model.apply(using: client)
        XCTAssertNotNil(model.review)
        XCTAssertNotNil(model.status)
        XCTAssertEqual(client.applied, 0)
        client.captureActive = false
        client.defaults.setVolatileDomain(["customVocabulary": "changed concurrently"],
                                          forName: UserDefaults.argumentDomain)
        model.apply(using: client)
        XCTAssertEqual(client.applied, 0)
        XCTAssertNotNil(model.review, "failure stays visible inside the review sheet")
        model.cancelReview()
        await model.importFile(using: client)
        model.apply(using: client)
        XCTAssertEqual(try client.portableSettingsSnapshot()[.vocabulary], .text("changed concurrently, Cóndor, Don’t, C++"))
    }

    func testCanceledLateReadCannotReopenReviewAndDuplicateActionDoesNotReadAgain() async throws {
        let client = try SettingsTransferTestClient()
        client.pauseRead = true
        let model = SettingsTransferModel()
        let task = Task { await model.importFile(using: client) }
        await client.waitForRead()
        await model.importFile(using: client)
        XCTAssertEqual(client.readCount, 1)
        model.cancelReview()
        client.releaseRead()
        await task.value
        XCTAssertFalse(model.isWorking)
        XCTAssertNil(model.review)
        XCTAssertNil(model.status)
        XCTAssertEqual(client.applied, 0)
    }

    func testPreferenceChangeDuringHeldReadRequiresANewReview() async throws {
        let client = try SettingsTransferTestClient()
        client.pauseRead = true
        let model = SettingsTransferModel()
        let task = Task { await model.importFile(using: client) }
        await client.waitForRead()
        client.defaults.setVolatileDomain(["customVocabulary": "newer user choice"],
                                          forName: UserDefaults.argumentDomain)
        client.releaseRead()
        await task.value
        XCTAssertNotNil(model.review)
        model.apply(using: client)
        XCTAssertNotNil(model.review)
        XCTAssertNotNil(model.status)
        XCTAssertEqual(client.applied, 0)
        XCTAssertEqual(try client.portableSettingsSnapshot()[.vocabulary], .text("newer user choice"))
    }

    func testReadWritePanelAndPayloadFailuresHaveNoImplicitApply() async throws {
        let client = try SettingsTransferTestClient()
        let before = try client.portableSettingsSnapshot()
        let model = SettingsTransferModel()
        client.selection = nil
        await model.importFile(using: client)
        await model.export(using: client)
        XCTAssertNil(model.status)
        XCTAssertEqual(client.readCount, 0)
        XCTAssertTrue(client.written.isEmpty)
        client.selection = URL(fileURLWithPath: "/unused-test-selection.json")
        client.readError = true
        await model.importFile(using: client)
        XCTAssertNotNil(model.status)
        XCTAssertNil(model.review)
        client.readError = false
        for data in [Data(), Data("{}".utf8), Data("{\"password\":\"must-not-display\"}".utf8)] {
            client.input = data
            await model.importFile(using: client)
            XCTAssertNotNil(model.status)
            XCTAssertFalse(model.status?.contains("must-not-display") ?? true)
            XCTAssertNil(model.review)
        }
        client.writeError = true
        await model.export(using: client)
        XCTAssertTrue(client.written.isEmpty)
        XCTAssertNotNil(model.status)
        client.writeError = false
        await model.export(using: client)
        XCTAssertEqual(client.written.count, 1)
        XCTAssertEqual(try client.portableSettingsSnapshot(), before)
        XCTAssertEqual(client.applied, 0)
    }

    func testNoOpImportDoesNotPresentAnEmptyReview() async throws {
        let client = try SettingsTransferTestClient()
        client.input = try PortableSettingsTransfer.export([:])
        let model = SettingsTransferModel()
        await model.importFile(using: client)
        XCTAssertNil(model.review)
        XCTAssertNotNil(model.status)
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(client.applied, 0)
    }

    func testFileFixtureRequiresBothFlagsAndAnAbsoluteDestination() async {
        for operation in [SettingsTransferFileOperation.importFile, .exportFile] {
            let env = ["PORTAVOZ_UI_TEST_SETTINGS_IMPORT": "/tmp/import.json",
                       "PORTAVOZ_UI_TEST_SETTINGS_EXPORT": "/tmp/export.json"]
            for flags in [[], ["-use-temp-store"], ["-seed-settings-transfer"]] {
                XCTAssertNil(SettingsTransferUITestFileSelection.url(for: operation, arguments: flags, environment: env))
            }
            let flags = ["-use-temp-store", "-seed-settings-transfer"]
            XCTAssertNotNil(SettingsTransferUITestFileSelection.url(for: operation, arguments: flags, environment: env))
            XCTAssertNil(SettingsTransferUITestFileSelection.url(for: operation, arguments: flags,
                environment: env.mapValues { _ in "relative.json" }))
        }
    }
}

@MainActor
private final class SettingsTransferTestClient: SettingsTransferClient {
    let defaults = UserDefaults(suiteName: "settings-transfer-model-\(UUID().uuidString)")!
    var selection: URL? = URL(fileURLWithPath: "/unused-test-selection.json")
    var input: Data
    var written: [Data] = []
    var applied = 0
    var captureActive = false
    var readError = false
    var writeError = false
    var pauseRead = false
    var readCount = 0
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?

    init() throws {
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        input = try PortableSettingsTransfer.export([.vocabulary: .text("Cóndor, Don’t, C++")])
    }

    func portableSettingsSnapshot() throws -> [PortableSettingsKey: PortableSettingsValue] {
        try AppPortableSettingsStore(defaults: defaults, temporary: true).snapshot()
    }

    func applyPortableSettings(_ review: PortableSettingsReview) throws -> Int {
        let count = try AppPortableSettingsStore(defaults: defaults, temporary: true)
            .apply(review, captureActive: captureActive)
        applied += 1
        return count
    }

    func selectSettingsFile(_ operation: SettingsTransferFileOperation) -> URL? { selection }

    func readSettingsFile(_ url: URL) async throws -> Data {
        readCount += 1
        if pauseRead {
            await withCheckedContinuation { readContinuation = $0; startedContinuation?.resume(); startedContinuation = nil }
        }
        if readError { throw CocoaError(.fileReadUnknown) }
        return input
    }

    func writeSettingsFile(_ data: Data, to url: URL) async throws {
        if writeError { throw CocoaError(.fileWriteUnknown) }
        written.append(data)
    }

    func waitForRead() async {
        if readContinuation == nil { await withCheckedContinuation { startedContinuation = $0 } }
    }

    func releaseRead() { readContinuation?.resume(); readContinuation = nil }
}
