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
        let model = SemanticSearchPreparationModel(client: client)

        let first = Task { await model.prepare() }
        try await waitUntil { client.preparationContinuation != nil }
        await model.prepare()

        XCTAssertEqual(client.prepareCount, 1)
        XCTAssertEqual(model.phase, .preparing)
        client.resumePreparation()
        await first.value
        XCTAssertEqual(model.phase, .ready)
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

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline {
                XCTFail("condition did not become true before timeout")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum SemanticPreparationModelTestError: Error {
    case failed
}

@MainActor
private final class SemanticPreparationClient:
    SemanticSearchPreparationModelClient
{
    var currentReadiness: SemanticSearchAssetReadiness
    var prepared: SemanticSearchAssetReadiness
    var error: (any Error)?
    var suspendPreparation = false
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
        currentReadiness
    }

    func prepare() async throws -> SemanticSearchAssetReadiness {
        prepareCount += 1
        if suspendPreparation {
            await withCheckedContinuation { continuation in
                preparationContinuation = continuation
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
}
