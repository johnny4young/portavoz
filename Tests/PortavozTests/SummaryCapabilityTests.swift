import ApplicationKit
import Foundation
import IntelligenceKit
@testable import portavoz_app
import XCTest

final class SummaryCapabilityTests: XCTestCase {
    func testSequoiaFixtureCannotReportFoundationModelsAvailable() {
        XCTAssertEqual(
            FoundationModelsCapability.current(
                arguments: ["portavoz-app", "-simulate-sequoia-capabilities"]),
            .requiresMacOS26)
    }

    func testInitialPolicyUsesInstalledOllamaChatModel() {
        let choice = InitialSummaryEnginePolicy.choose(
            profile: HardwareProfile(
                memoryGB: 16,
                appleIntelligence: false,
                ollamaAvailable: true,
                freeDiskGB: 100),
            ollamaModels: ["minicpm-v:ocr", "llama3.2:latest"])

        XCTAssertEqual(
            choice,
            InitialSummaryEngineConfiguration(
                engine: .ollama,
                ollamaModel: "llama3.2:latest"))
    }

    func testInitialPolicyFallsBackToMLXWhenOllamaHasNoChatModel() {
        let choice = InitialSummaryEnginePolicy.choose(
            profile: HardwareProfile(
                memoryGB: 16,
                appleIntelligence: false,
                ollamaAvailable: true,
                freeDiskGB: 100),
            ollamaModels: ["MINICPM-OCR"])

        XCTAssertEqual(
            choice,
            InitialSummaryEngineConfiguration(engine: .mlx, ollamaModel: nil))
    }

    func testSelectedOllamaWithoutModelDoesNotFallThroughToApple() {
        let resolver = AppSummaryRegenerationProviderResolver(
            defaultEngine: .ollama,
            ollamaModel: nil,
            mlxModelDirectory: nil,
            foundationModelsCapability: .available)

        switch resolver.resolve(override: nil) {
        case .unavailable(.ollamaModelNotSelected):
            break
        default:
            XCTFail("a selected but unconfigured Ollama engine must remain explicit")
        }
    }

    func testSelectedMLXWithoutDownloadDoesNotFallThroughToApple() {
        let resolver = AppSummaryRegenerationProviderResolver(
            defaultEngine: .mlx,
            ollamaModel: nil,
            mlxModelDirectory: nil,
            foundationModelsCapability: .available)

        switch resolver.resolve(override: nil) {
        case .unavailable(.mlxModelNotDownloaded):
            break
        default:
            XCTFail("a selected but unprepared MLX engine must remain explicit")
        }
    }
}
