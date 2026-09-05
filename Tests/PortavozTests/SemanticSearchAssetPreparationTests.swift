import ApplicationKit
import PortavozCore
import XCTest

final class SemanticSearchAssetPreparationTests: XCTestCase {
    func testInspectionDoesNotPrepareOrDownloadAssets() async {
        let runtime = SemanticAssetRuntime(
            profile: Self.profile,
            assetsAvailable: false)

        let readiness = await InspectSemanticSearchAssets(
            runtime: runtime
        ).current()
        let requests = await runtime.preparationRequests

        XCTAssertEqual(readiness, .needsPreparation)
        XCTAssertEqual(requests, [])
    }

    func testMissingProfileIsUnsupportedWithoutPreparation() async throws {
        let runtime = SemanticAssetRuntime(
            profile: nil,
            assetsAvailable: false)

        let readiness = try await PrepareSemanticSearchAssets(
            runtime: runtime
        ).execute()
        let requests = await runtime.preparationRequests

        XCTAssertEqual(readiness, .unsupported)
        XCTAssertEqual(requests, [])
    }

    func testExplicitPreparationIsTheOnlyPathThatAllowsDownload() async throws {
        let runtime = SemanticAssetRuntime(
            profile: Self.profile,
            assetsAvailable: false,
            becomesAvailableAfterPreparation: true)

        let readiness = try await PrepareSemanticSearchAssets(
            runtime: runtime
        ).execute()
        let requests = await runtime.preparationRequests

        XCTAssertEqual(readiness, .ready)
        XCTAssertEqual(requests, [true])
    }

    func testInstalledAssetsLoadWithoutDownloadPermission() async throws {
        let runtime = SemanticAssetRuntime(
            profile: Self.profile,
            assetsAvailable: true)

        let readiness = try await PrepareSemanticSearchAssets(
            runtime: runtime
        ).execute()
        let requests = await runtime.preparationRequests

        XCTAssertEqual(readiness, .ready)
        XCTAssertEqual(requests, [false])
    }

    func testPreparationFailureDoesNotInventReadiness() async {
        let runtime = SemanticAssetRuntime(
            profile: Self.profile,
            assetsAvailable: false,
            preparationFails: true)

        do {
            _ = try await PrepareSemanticSearchAssets(
                runtime: runtime
            ).execute()
            XCTFail("expected the OS asset request failure to propagate")
        } catch {
            XCTAssertEqual(error as? SemanticAssetTestError, .failed)
        }

        let requests = await runtime.preparationRequests
        let readiness = await InspectSemanticSearchAssets(
            runtime: runtime
        ).current()
        XCTAssertEqual(requests, [true])
        XCTAssertEqual(readiness, .needsPreparation)
    }

    private static let profile = SemanticEmbeddingProfile(
        modelIdentifier: "semantic-assets-test-model",
        modelRevision: 1,
        vectorDimension: 2,
        pipelineIdentifier: "semantic-assets-test-pipeline",
        pipelineRevision: 1,
        vectorSchemaVersion: 1)
}

private enum SemanticAssetTestError: Error, Equatable {
    case failed
}

private actor SemanticAssetRuntime: SemanticEmbeddingRuntimeClient {
    private let profile: SemanticEmbeddingProfile?
    private var assetsAvailable: Bool
    private let becomesAvailableAfterPreparation: Bool
    private let preparationFails: Bool
    private(set) var preparationRequests: [Bool] = []

    init(
        profile: SemanticEmbeddingProfile?,
        assetsAvailable: Bool,
        becomesAvailableAfterPreparation: Bool = false,
        preparationFails: Bool = false
    ) {
        self.profile = profile
        self.assetsAvailable = assetsAvailable
        self.becomesAvailableAfterPreparation = becomesAvailableAfterPreparation
        self.preparationFails = preparationFails
    }

    var hasAvailableAssets: Bool { assetsAvailable }

    func semanticEmbeddingProfile() -> SemanticEmbeddingProfile? { profile }

    func prepare(allowAssetDownload: Bool) throws {
        preparationRequests.append(allowAssetDownload)
        if preparationFails { throw SemanticAssetTestError.failed }
        if allowAssetDownload, becomesAvailableAfterPreparation {
            assetsAvailable = true
        }
    }

    func withPreparedEmbedding<Result: Sendable>(
        allowAssetDownload _: Bool,
        operation _: @Sendable (
            _ embedder: any SemanticTextEmbedding
        ) async throws -> Result
    ) async throws -> Result {
        throw SemanticAssetTestError.failed
    }
}
