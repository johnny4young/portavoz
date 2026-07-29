import ApplicationKit
import Foundation
import IntelligenceKit
import PortavozCore
@testable import portavoz_app
import XCTest

final class SummaryCapabilityTests: XCTestCase {
    func testSequoiaFixtureCannotReportFoundationModelsAvailable() {
        XCTAssertEqual(
            FoundationModelsCapability.current(
                arguments: ["portavoz-app", "-simulate-sequoia-capabilities"]),
            .requiresMacOS26)
    }

    func testSelectedOllamaWithoutModelDoesNotFallThroughToApple() async {
        let resolver = AppSummaryRegenerationProviderResolver(
            defaultEngine: .ollama,
            ollamaModel: nil,
            mlxModelDirectory: { nil },
            mlxProvider: { _, _ in SummaryCapabilityProviderStub() },
            foundationModelsCapability: .available,
            gateway: TestDataEgressGateway())

        switch await resolver.resolve(override: nil) {
        case .unavailable(.ollamaModelNotSelected):
            break
        default:
            XCTFail("a selected but unconfigured Ollama engine must remain explicit")
        }
    }

    func testSelectedMLXWithoutDownloadDoesNotFallThroughToApple() async {
        let resolver = AppSummaryRegenerationProviderResolver(
            defaultEngine: .mlx,
            ollamaModel: nil,
            mlxModelDirectory: { nil },
            mlxProvider: { _, _ in SummaryCapabilityProviderStub() },
            foundationModelsCapability: .available,
            gateway: TestDataEgressGateway())

        switch await resolver.resolve(override: nil) {
        case .unavailable(.mlxModelNotDownloaded):
            break
        default:
            XCTFail("a selected but unprepared MLX engine must remain explicit")
        }
    }

    func testSelectedMLXAcceptsVerifiedDirectoryEvidence() async {
        let directory = URL(fileURLWithPath: "/verified/model", isDirectory: true)
        let resolver = AppSummaryRegenerationProviderResolver(
            defaultEngine: .mlx,
            ollamaModel: nil,
            mlxModelDirectory: { directory },
            mlxProvider: { _, _ in SummaryCapabilityProviderStub() },
            foundationModelsCapability: .unavailable("unused"),
            gateway: TestDataEgressGateway())

        guard case .available = await resolver.resolve(override: nil) else {
            return XCTFail("verified MLX installation evidence should resolve the provider")
        }
    }
}

private struct SummaryCapabilityProviderStub: SummaryProvider {
    func summarize(_ request: SummaryRequest) async throws -> SummaryDraft {
        throw CancellationError()
    }
}
