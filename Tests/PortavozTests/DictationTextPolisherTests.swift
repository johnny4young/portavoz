import Foundation
@testable import IntegrationsKit
@testable import IntelligenceKit
import PortavozCore
import XCTest

final class DictationTextPolisherTests: XCTestCase {
    func testOllamaPolishSendsOnlyTheDictationToLoopbackWithPolishMetadata() async throws {
        let gateway = CapturingDataEgressGateway(responseData: Self.chat("\"Mañana enviamos el informe.\""))
        let polisher = OllamaService.dictationPolisher(model: "qwen-local", gateway: gateway)

        let polished = try await polisher.polish("eh mañana enviamos el informe")

        XCTAssertEqual(polished, "Mañana enviamos el informe.")
        let snapshot = await gateway.snapshot()
        let captured = try XCTUnwrap(snapshot)
        XCTAssertEqual(captured.metadata.operation, .dictationPolish)
        XCTAssertEqual(captured.metadata.dataClassification, .dictationText)
        XCTAssertEqual(captured.metadata.consentSource, .dictationPolishMode)
        XCTAssertEqual(captured.metadata.destination.scope, .localDevice)
        XCTAssertNil(captured.metadata.meetingID)
        XCTAssertEqual(captured.metadata.providerDisclosure.modelID, "qwen-local")
        XCTAssertNoThrow(try URLSessionDataEgressGateway.validate(captured.request, metadata: captured.metadata))

        let body = try XCTUnwrap(captured.request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["temperature"] as? Double, 0)
        XCTAssertEqual(json["max_tokens"] as? Int, 64)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["content"], DictationPolishPrompt.instructions)
        XCTAssertTrue(messages.last?["content"]?.contains("<dictation>\neh mañana enviamos el informe\n</dictation>") == true)
    }

    func testOllamaPolishRefusesOversizedTextBeforeTransport() async {
        let gateway = CapturingDataEgressGateway()
        let polisher = OllamaService.dictationPolisher(model: "qwen-local", gateway: gateway)

        do {
            _ = try await polisher.polish(String(repeating: "a", count: 2_001))
            XCTFail("text over the polish bound must not be sent")
        } catch {
            XCTAssertEqual(
                error as? DictationPolishPromptError,
                .textTooLong(actualCharacters: 2_001, maximumCharacters: 2_000))
        }
        let snapshot = await gateway.snapshot()
        XCTAssertNil(snapshot)
    }

    func testMLXPolishUsesTheInjectedRuntimeWithABoundedBudget() async throws {
        let directory = URL(fileURLWithPath: "/verified/qwen", isDirectory: true)
        let runtime = MLXPolishRuntimeSpy(response: "```\nSend the report on Friday.\n```")
        let polisher = MLXDictationPolisher(modelDirectory: directory, runtime: runtime)
        let text = String(repeating: "send the report on friday ", count: 20)

        let polished = try await polisher.polish(text)

        XCTAssertEqual(polished, "Send the report on Friday.")
        let captured = await runtime.request()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.directory, directory)
        XCTAssertEqual(request.system, DictationPolishPrompt.instructions)
        XCTAssertTrue(request.user.contains("<dictation>"))
        XCTAssertEqual(request.maximumResponseTokens, (text.trimmingCharacters(in: .whitespaces).count + 1) / 2)
    }

    func testMLXPolishPropagatesRuntimeRefusalUnchanged() async {
        let runtime = MLXPolishRuntimeSpy(response: "", failure: MLXSummaryRuntimeError.notPrepared)
        let polisher = MLXDictationPolisher(
            modelDirectory: URL(fileURLWithPath: "/verified/qwen"), runtime: runtime)

        do {
            _ = try await polisher.polish("hola qué tal")
            XCTFail("a runtime refusal must surface")
        } catch {
            XCTAssertEqual(error as? MLXSummaryRuntimeError, .notPrepared)
        }
    }

    @available(macOS 26.0, *)
    func testAppleUnavailableModelThrowsPolishUnavailableWithItsReason() async {
        let polisher = FoundationModelDictationPolisher(unavailabilityReason: { "Apple Intelligence is turned off" })

        do {
            _ = try await polisher.polish("hola qué tal")
            XCTFail("an unavailable on-device model must not run")
        } catch {
            XCTAssertEqual(
                error as? DictationPolishUnavailable,
                DictationPolishUnavailable(reason: "Apple Intelligence is turned off"))
        }
    }

    private static func chat(_ content: String) -> Data {
        let body: [String: Any] = ["choices": [["message": ["content": content]]]]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }
}

private actor MLXPolishRuntimeSpy: MLXSummaryRuntimeClient {
    struct Request: Sendable {
        let system: String
        let user: String
        let directory: URL
        let maximumResponseTokens: Int?
    }

    private let response: String
    private let failure: (any Error)?
    private var captured: Request?

    init(response: String, failure: (any Error)? = nil) {
        self.response = response
        self.failure = failure
    }

    func respond(system: String, user: String, directory: URL) throws -> String {
        try record(Request(system: system, user: user, directory: directory, maximumResponseTokens: nil))
    }

    func respond(system: String, user: String, directory: URL, maximumResponseTokens: Int) throws -> String {
        try record(Request(
            system: system, user: user, directory: directory, maximumResponseTokens: maximumResponseTokens))
    }

    private func record(_ request: Request) throws -> String {
        captured = request
        if let failure { throw failure }
        return response
    }

    func request() -> Request? { captured }
}
