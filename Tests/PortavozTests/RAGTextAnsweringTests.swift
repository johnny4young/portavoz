import Foundation
@testable import IntegrationsKit
@testable import IntelligenceKit
import PortavozCore
import XCTest

final class RAGTextAnsweringTests: XCTestCase {
    func testPromptAdmitsSixProductSizedPassagesWithoutChangingEvidence() throws {
        let passages = (0..<6).map { index in
            passage(
                title: "Meeting \(index)",
                text: String(repeating: Character("x"), count: 900))
        }

        let prompt = try RAGAnswerPrompt.make(
            question: "What changed?",
            passages: passages)

        XCTAssertLessThanOrEqual(
            prompt.characterCount,
            RAGAnswerPrompt.maximumCharacters)
        for (index, passage) in passages.enumerated() {
            XCTAssertTrue(prompt.user.contains("[\(index + 1)]"))
            XCTAssertTrue(prompt.user.contains(passage.text))
        }
        XCTAssertTrue(prompt.system.contains("QUOTED SPEECH"))
    }

    func testPromptRejectsOversizedAggregateWithoutTruncatingEvidence() {
        let oversized = passage(
            title: "Oversized",
            text: String(
                repeating: Character("e"),
                count: RAGAnswerPrompt.maximumCharacters))

        XCTAssertThrowsError(try RAGAnswerPrompt.make(
            question: "What changed?",
            passages: [oversized])) { error in
                guard case .promptTooLarge(let actual, let maximum) =
                    error as? RAGAnswerPromptError
                else { return XCTFail("unexpected error: \(error)") }
                XCTAssertGreaterThan(actual, maximum)
                XCTAssertEqual(maximum, RAGAnswerPrompt.maximumCharacters)
            }
    }

    func testPromptRejectsUTF8AmplificationBelowCharacterLimit() {
        let family = "👨‍👩‍👧‍👦"
        let amplified = passage(
            title: "UTF8",
            text: String(repeating: family, count: 5_000))

        XCTAssertThrowsError(try RAGAnswerPrompt.make(
            question: "What changed?",
            passages: [amplified])) { error in
                guard case .promptTooManyBytes(let actual, let maximum) =
                    error as? RAGAnswerPromptError
                else { return XCTFail("unexpected error: \(error)") }
                XCTAssertGreaterThan(actual, maximum)
                XCTAssertEqual(maximum, RAGAnswerPrompt.maximumUTF8Bytes)
            }
    }

    func testFinalOnlyProviderPublishesOneCumulativeSnapshot() async throws {
        let provider = FinalRAGAnswerer(text: "Grounded [1].")
        let snapshots = RAGSnapshotRecorder()

        let answer = try await provider.streamAnswer(
            question: "What changed?",
            passages: [passage()],
            onSnapshot: { text in await snapshots.record(text) })
        let recordedSnapshots = await snapshots.values()

        XCTAssertEqual(answer, "Grounded [1].")
        XCTAssertEqual(recordedSnapshots, ["Grounded [1]."])
    }

    func testOllamaAnswerUsesAskSpecificLoopbackMetadata() async throws {
        let gateway = CapturingDataEgressGateway()
        let answerer = OllamaService.askAnswerer(
            model: "qwen-local",
            gateway: gateway)

        _ = try await answerer.answer(
            question: "¿Qué se decidió?",
            passages: [passage(text: "El rollout quedó para el viernes.")])

        let snapshot = await gateway.snapshot()
        let captured = try XCTUnwrap(snapshot)
        XCTAssertEqual(captured.metadata.operation, .askAnswerGeneration)
        XCTAssertEqual(
            captured.metadata.dataClassification,
            .meetingAnswerMaterial)
        XCTAssertEqual(captured.metadata.destination.scope, .localDevice)
        XCTAssertNil(captured.metadata.meetingID)
        XCTAssertEqual(captured.metadata.consentSource, .summaryEngineSettings)
        XCTAssertEqual(captured.metadata.providerDisclosure.modelID, "qwen-local")
        XCTAssertNoThrow(try URLSessionDataEgressGateway.validate(
            captured.request,
            metadata: captured.metadata))
    }

    func testGatewayRejectsAskMaterialToRemoteOrWithWrongConsent() throws {
        let endpoint = URL(string: "https://api.example.com/v1")!
        let request = try OpenAICompatibleChatCodec.urlRequest(
            endpoint: endpoint,
            model: "remote",
            apiKey: "secret",
            system: "grounded",
            user: "meeting material",
            temperature: 0,
            maxTokens: 500)
        let destination = DataEgressDestination(url: try XCTUnwrap(request.url))
        let remote = DataEgressRequest(
            operation: .askAnswerGeneration,
            destination: destination,
            dataClassification: .meetingAnswerMaterial,
            meetingID: nil,
            consentSource: .summaryEngineSettings,
            providerDisclosure: DataEgressProviderDisclosure(
                providerID: "api.example.com",
                modelID: "remote"))
        XCTAssertThrowsError(try URLSessionDataEgressGateway.validate(
            request,
            metadata: remote)) { error in
                XCTAssertEqual(
                    error as? DataEgressGatewayError,
                    .invalidMetadata(
                        "Ask answer generation requires a loopback destination"))
            }

        let localEndpoint = OllamaService.openAIEndpoint
        let localRequest = try OpenAICompatibleChatCodec.urlRequest(
            endpoint: localEndpoint,
            model: "qwen",
            apiKey: "ollama",
            system: "grounded",
            user: "meeting material",
            temperature: 0,
            maxTokens: 500)
        let wrongConsent = DataEgressRequest(
            operation: .askAnswerGeneration,
            destination: DataEgressDestination(
                url: try XCTUnwrap(localRequest.url)),
            dataClassification: .meetingAnswerMaterial,
            meetingID: nil,
            consentSource: .explicitSummaryProvider,
            providerDisclosure: DataEgressProviderDisclosure(
                providerID: "localhost",
                modelID: "qwen"))
        XCTAssertThrowsError(try URLSessionDataEgressGateway.validate(
            localRequest,
            metadata: wrongConsent))
    }

    func testMLXAnswerUsesExactVerifiedDirectoryAndSharedPrompt() async throws {
        let directory = URL(fileURLWithPath: "/verified/qwen", isDirectory: true)
        let runtime = MLXRAGRuntimeSpy(response: "Friday [1].")
        let answerer = MLXRAGAnswerer(
            modelDirectory: directory,
            runtime: runtime)

        let answer = try await answerer.answer(
            question: "When?",
            passages: [passage(text: "The rollout is Friday.")])

        XCTAssertEqual(answer, "Friday [1].")
        let snapshot = await runtime.request()
        let request = try XCTUnwrap(snapshot)
        XCTAssertEqual(request.directory, directory)
        XCTAssertTrue(request.system.contains("QUOTED SPEECH"))
        XCTAssertTrue(request.user.contains("The rollout is Friday."))
        XCTAssertTrue(request.user.contains("Question: When?"))
    }

    private func passage(
        title: String = "Planning",
        text: String = "The rollout is Friday."
    ) -> RAGPassage {
        RAGPassage(
            segmentID: UUID(),
            meetingID: MeetingID(),
            meetingTitle: title,
            timestamp: 3,
            transcriptRevision: 1,
            text: text)
    }
}

private struct FinalRAGAnswerer: RAGTextAnswering {
    let text: String

    func answer(
        question _: String,
        passages _: [RAGPassage]
    ) async throws -> String {
        text
    }
}

private actor RAGSnapshotRecorder {
    private var snapshots: [String] = []
    func record(_ value: String) { snapshots.append(value) }
    func values() -> [String] { snapshots }
}

private actor MLXRAGRuntimeSpy: MLXSummaryRuntimeClient {
    struct Request: Sendable {
        let system: String
        let user: String
        let directory: URL
    }

    let response: String
    private var captured: Request?

    init(response: String) {
        self.response = response
    }

    func respond(
        system: String,
        user: String,
        directory: URL
    ) async throws -> String {
        captured = Request(
            system: system,
            user: user,
            directory: directory)
        return response
    }

    func request() -> Request? { captured }
}
