import ApplicationKit
import PortavozCore
@testable import portavoz_app
import XCTest

@MainActor
final class SemanticSearchPreparationModelTests: XCTestCase {
    func testRefreshReportsMissingAssetsWithoutPreparing() async {
        let client = SemanticPreparationClient(current: .needsPreparation)
        let model = SemanticSearchPreparationModel(client: client)

        await model.refresh()

        XCTAssertEqual(model.phase, .needsPreparation)
        XCTAssertEqual(client.prepareCount, 0)
    }

    func testExplicitPreparationPublishesReady() async {
        let client = SemanticPreparationClient(
            current: .needsPreparation,
            prepared: .ready)
        let model = SemanticSearchPreparationModel(client: client)

        await model.refresh()
        await model.prepare()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(client.prepareCount, 1)
    }

    func testCompetingPreparationRequestDoesNotStartASecondOperation() async throws {
        let client = SemanticPreparationClient(
            current: .needsPreparation,
            prepared: .ready)
        client.suspendPreparation = true
        let entered = expectation(description: "preparation entered")
        client.onPreparationStarted = { entered.fulfill() }
        let model = SemanticSearchPreparationModel(client: client)

        let first = Task { await model.prepare() }
        defer {
            first.cancel()
            client.resumePreparation()
        }
        await fulfillment(of: [entered], timeout: 5)
        _ = try XCTUnwrap(client.preparationContinuation)
        await model.refresh()
        await model.prepare()

        XCTAssertEqual(client.inspectionCount, 0)
        XCTAssertEqual(client.prepareCount, 1)
        XCTAssertEqual(model.phase, .preparing)
        client.resumePreparation()
        await first.value
        XCTAssertEqual(model.phase, .ready)
    }

    func testStaleRefreshCannotReopenPreparationWhileItIsRunning() async throws {
        let client = SemanticPreparationClient(current: .needsPreparation, prepared: .ready)
        let model = SemanticSearchPreparationModel(client: client)
        await model.refresh()
        client.suspendInspection = true
        client.suspendPreparation = true
        let inspected = expectation(description: "old inspection entered")
        let preparing = expectation(description: "preparation entered")
        client.onInspectionStarted = { _ in inspected.fulfill() }
        client.onPreparationStarted = { preparing.fulfill() }

        let refresh = Task { await model.refresh() }
        defer {
            refresh.cancel()
            client.resumeInspections()
        }
        await fulfillment(of: [inspected], timeout: 5)
        _ = try XCTUnwrap(client.inspectionContinuations[2])
        let preparation = Task { await model.prepare() }
        defer {
            preparation.cancel()
            client.resumePreparation()
        }
        await fulfillment(of: [preparing], timeout: 5)
        _ = try XCTUnwrap(client.preparationContinuation)

        client.resumeInspection(2, returning: .needsPreparation)
        await refresh.value
        XCTAssertEqual(model.phase, .preparing)
        // Do not start an intentionally duplicate flight on an unfixed model:
        // the stale phase assertion above is the regression oracle.
        guard model.phase == .preparing else { return }
        await model.prepare()
        XCTAssertEqual(client.prepareCount, 1)
        client.resumePreparation()
        await preparation.value
        XCTAssertEqual(model.phase, .ready)
    }

    func testStaleRefreshCannotReplaceCompletedPreparation() async throws {
        let client = SemanticPreparationClient(current: .needsPreparation, prepared: .ready)
        let model = SemanticSearchPreparationModel(client: client)
        await model.refresh()
        client.suspendInspection = true
        let entered = expectation(description: "old inspection entered")
        client.onInspectionStarted = { _ in entered.fulfill() }
        let refresh = Task { await model.refresh() }
        defer {
            refresh.cancel()
            client.resumeInspections()
        }
        await fulfillment(of: [entered], timeout: 5)
        _ = try XCTUnwrap(client.inspectionContinuations[2])

        await model.prepare()
        XCTAssertEqual(model.phase, .ready)
        client.resumeInspection(2, returning: .needsPreparation)
        await refresh.value

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(client.prepareCount, 1)
    }

    func testNewestRefreshWinsWhenInspectionsFinishOutOfOrder() async throws {
        let client = SemanticPreparationClient(current: .needsPreparation)
        client.suspendInspection = true
        let model = SemanticSearchPreparationModel(client: client)
        let firstEntered = expectation(description: "first inspection entered")
        let secondEntered = expectation(description: "second inspection entered")
        client.onInspectionStarted = { request in
            (request == 1 ? firstEntered : secondEntered).fulfill()
        }
        let first = Task { await model.refresh() }
        defer {
            first.cancel()
            client.resumeInspections()
        }
        await fulfillment(of: [firstEntered], timeout: 5)
        _ = try XCTUnwrap(client.inspectionContinuations[1])
        let second = Task { await model.refresh() }
        defer { second.cancel() }
        await fulfillment(of: [secondEntered], timeout: 5)
        _ = try XCTUnwrap(client.inspectionContinuations[2])

        client.resumeInspection(2, returning: .ready)
        await second.value
        client.resumeInspection(1, returning: .needsPreparation)
        await first.value

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(client.prepareCount, 0)
    }

    func testCancelledRefreshCannotPublishLateReadiness() async throws {
        let client = SemanticPreparationClient(current: .needsPreparation)
        let model = SemanticSearchPreparationModel(client: client)
        await model.refresh()
        client.suspendInspection = true
        let entered = expectation(description: "inspection entered")
        client.onInspectionStarted = { _ in entered.fulfill() }
        let refresh = Task { await model.refresh() }
        defer {
            refresh.cancel()
            client.resumeInspections()
        }
        await fulfillment(of: [entered], timeout: 5)
        _ = try XCTUnwrap(client.inspectionContinuations[2])

        refresh.cancel()
        client.resumeInspection(2, returning: .unsupported)
        await refresh.value

        XCTAssertEqual(model.phase, .needsPreparation)
        XCTAssertEqual(client.prepareCount, 0)
    }

    func testCaptureAdmissionFailureRemainsRetryable() async {
        let client = SemanticPreparationClient(current: .needsPreparation)
        client.error = AppResourceGovernorAdmissionError.activeCaptureModelConflict
        let model = SemanticSearchPreparationModel(client: client)

        await model.prepare()

        XCTAssertEqual(model.phase, .blockedByCapture)
        client.error = nil
        client.prepared = .ready
        await model.prepare()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(client.prepareCount, 2)
    }

    func testOrdinaryFailureRemainsRetryable() async {
        let client = SemanticPreparationClient(current: .needsPreparation)
        client.error = SemanticPreparationModelTestError.failed
        let model = SemanticSearchPreparationModel(client: client)

        await model.prepare()

        XCTAssertEqual(model.phase, .failed)
        client.error = nil
        client.prepared = .ready
        await model.prepare()
        XCTAssertEqual(model.phase, .ready)
    }

    func testDisposableMissingAssetModelChangesOnlyAfterExplicitDownload() async throws {
        let makeModel = AppServices.makeSemanticEmbeddingModelFactory(
            arguments: ["-use-temp-store", "-simulate-semantic-assets-missing"],
            usesTemporaryStore: true)
        let model = try makeModel()

        let assetsBefore = await model.hasAvailableAssets
        XCTAssertFalse(assetsBefore)
        try await model.prepare(allowAssetDownload: true)
        let assetsAfter = await model.hasAvailableAssets
        XCTAssertTrue(assetsAfter)
    }
}

private enum SemanticPreparationModelTestError: Error {
    case failed
}

@MainActor
private final class SemanticPreparationClient:
    SemanticSearchPreparationModelClient {
    var currentReadiness: SemanticSearchAssetReadiness
    var prepared: SemanticSearchAssetReadiness
    var error: (any Error)?
    var suspendPreparation = false
    var suspendInspection = false
    var onInspectionStarted: ((Int) -> Void)?
    var onPreparationStarted: (() -> Void)?
    private(set) var inspectionCount = 0
    private(set) var inspectionContinuations:
        [Int: CheckedContinuation<SemanticSearchAssetReadiness, Never>] = [:]
    private(set) var prepareCount = 0
    private(set) var preparationContinuation: CheckedContinuation<Void, Never>?

    init(
        current: SemanticSearchAssetReadiness,
        prepared: SemanticSearchAssetReadiness = .needsPreparation
    ) {
        currentReadiness = current
        self.prepared = prepared
    }

    func current() async -> SemanticSearchAssetReadiness {
        inspectionCount += 1
        guard suspendInspection, !Task.isCancelled else { return currentReadiness }
        return await withCheckedContinuation { continuation in
            inspectionContinuations[inspectionCount] = continuation
            onInspectionStarted?(inspectionCount)
        }
    }

    func prepare() async throws -> SemanticSearchAssetReadiness {
        prepareCount += 1
        if suspendPreparation, !Task.isCancelled {
            await withCheckedContinuation { continuation in
                preparationContinuation = continuation
                onPreparationStarted?()
            }
        }
        if let error { throw error }
        currentReadiness = prepared
        return prepared
    }

    func resumePreparation() {
        suspendPreparation = false
        preparationContinuation?.resume()
        preparationContinuation = nil
    }

    func resumeInspection(_ request: Int, returning readiness: SemanticSearchAssetReadiness) {
        guard let continuation = inspectionContinuations.removeValue(forKey: request) else {
            XCTFail("requested inspection did not enter")
            return
        }
        continuation.resume(returning: readiness)
    }

    func resumeInspections() {
        suspendInspection = false
        let pending = Array(inspectionContinuations.values)
        inspectionContinuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: currentReadiness)
        }
    }
}
