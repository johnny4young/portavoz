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

    func testManualAskKeepsAppleUnavailableOnSequoia() async {
        let resolver = AppSummaryRegenerationProviderResolver(
            defaultEngine: .appleOnDevice,
            ollamaModel: "unused",
            mlxModelDirectory: { nil },
            mlxProvider: { _, _ in SummaryCapabilityProviderStub() },
            foundationModelsCapability: .requiresMacOS26,
            gateway: TestDataEgressGateway())

        switch await resolver.resolveAsk(
            mlxProvider: { _, _ in RAGCapabilityProviderStub() }) {
        case .unavailable(.requiresMacOS26):
            break
        default:
            XCTFail("Apple Foundation Models must remain explicitly unavailable on Sequoia")
        }
    }

    func testManualAskResolvesConfiguredOllamaOnSequoia() async throws {
        let gateway = CapturingDataEgressGateway()
        let resolver = AppSummaryRegenerationProviderResolver(
            defaultEngine: .ollama,
            ollamaModel: "qwen-local",
            mlxModelDirectory: { nil },
            mlxProvider: { _, _ in SummaryCapabilityProviderStub() },
            foundationModelsCapability: .requiresMacOS26,
            gateway: gateway)

        guard case .available(let provider) = await resolver.resolveAsk(
            mlxProvider: { _, _ in RAGCapabilityProviderStub() })
        else { return XCTFail("configured Ollama should answer manual Ask on Sequoia") }

        _ = try await provider.answer(
            question: "What changed?",
            passages: [RAGPassage(
                meetingID: MeetingID(),
                meetingTitle: "Planning",
                timestamp: 0,
                text: "Friday")])
        let operation = await gateway.snapshot()?.metadata.operation
        XCTAssertEqual(operation, .askAnswerGeneration)
    }

    func testManualAskResolvesVerifiedMLXOnSequoiaWithoutFallback() async throws {
        let directory = URL(fileURLWithPath: "/verified/model", isDirectory: true)
        let provider = RAGCapabilityProviderStub()
        let resolver = AppSummaryRegenerationProviderResolver(
            defaultEngine: .mlx,
            ollamaModel: "unused",
            mlxModelDirectory: { directory },
            mlxProvider: { _, _ in SummaryCapabilityProviderStub() },
            foundationModelsCapability: .requiresMacOS26,
            gateway: TestDataEgressGateway())

        guard case .available(let resolved) = await resolver.resolveAsk(
            mlxProvider: { resolvedDirectory, _ in
                XCTAssertEqual(resolvedDirectory, directory)
                return provider
            })
        else { return XCTFail("verified MLX should answer manual Ask on Sequoia") }

        let answer = try await resolved.answer(question: "Q", passages: [])
        XCTAssertEqual(answer, "mlx")
    }
}

private struct SummaryCapabilityProviderStub: SummaryProvider {
    func summarize(_ request: SummaryRequest) async throws -> SummaryDraft {
        throw CancellationError()
    }
}

private struct RAGCapabilityProviderStub: RAGTextAnswering {
    func answer(
        question _: String,
        passages _: [RAGPassage]
    ) async throws -> String {
        "mlx"
    }
}
