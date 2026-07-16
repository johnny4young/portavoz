import Foundation
@testable import IntegrationsKit
@testable import IntelligenceKit
import PortavozCore
import XCTest

final class DataEgressGatewayTests: XCTestCase {
    private let meetingID = MeetingID(
        rawValue: UUID(uuidString: "E6000000-0000-0000-0000-000000000001")!)

    func testDestinationScopeRecognizesOnlyProvableLoopback() {
        for raw in [
            "http://localhost:11434/v1",
            "http://models.localhost:11434/v1",
            "http://127.0.0.42:11434/v1",
            "http://[::1]:11434/v1",
        ] {
            XCTAssertEqual(
                DataEgressDestination(url: URL(string: raw)!).scope,
                .localDevice,
                raw)
        }
        for raw in [
            "https://api.example.com/v1",
            "http://192.168.1.20:11434/v1",
            "http://ollama.local:11434/v1",
            "http://127.example.com/v1",
        ] {
            XCTAssertEqual(
                DataEgressDestination(url: URL(string: raw)!).scope,
                .remote,
                raw)
        }
    }

    func testCompanionClientRoutesQuestionOnlyWithRemoteMetadata() async throws {
        let gateway = CapturingDataEgressGateway()
        let client = CompanionBYOKClient(
            endpoint: URL(string: "https://api.example.com/v1")!,
            model: "companion-model",
            apiKey: "secret",
            gateway: gateway)

        let answer = try await client.completeCompanionQuestion(
            system: "Static Companion instructions",
            user: "¿Qué diferencia hay entre var y let?",
            maxTokens: 400,
            context: CompanionDataEgressContext(
                meetingID: meetingID,
                consentSource: .companionBYOKSettings))

        XCTAssertEqual(answer, "Use let by default.")
        let snapshot = await gateway.snapshot()
        let captured = try XCTUnwrap(snapshot)
        XCTAssertEqual(captured.metadata.operation, .companionKnowledgeAnswer)
        XCTAssertEqual(captured.metadata.destination.scope, .remote)
        XCTAssertEqual(captured.metadata.dataClassification, .meetingQuestionOnly)
        XCTAssertEqual(captured.metadata.meetingID, meetingID)
        XCTAssertEqual(captured.metadata.consentSource, .companionBYOKSettings)
        XCTAssertEqual(captured.metadata.providerDisclosure.providerID, "api.example.com")
        XCTAssertEqual(captured.metadata.providerDisclosure.modelID, "companion-model")
        XCTAssertNoThrow(try URLSessionDataEgressGateway.validate(
            captured.request,
            metadata: captured.metadata))
        XCTAssertEqual(
            captured.request.url?.absoluteString,
            "https://api.example.com/v1/chat/completions")

        let body = try XCTUnwrap(captured.request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["content"] }, [
            "Static Companion instructions",
            "¿Qué diferencia hay entre var y let?",
        ])
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("recent transcript"))
    }

    func testCompanionClientMarksLoopbackAsLocal() async throws {
        let gateway = CapturingDataEgressGateway()
        let client = CompanionBYOKClient(
            endpoint: URL(string: "http://localhost:11434/v1")!,
            model: "qwen-local",
            apiKey: "local",
            gateway: gateway)

        _ = try await client.completeCompanionQuestion(
            system: "Static",
            user: "What is an actor?",
            maxTokens: 100,
            context: CompanionDataEgressContext(
                meetingID: meetingID,
                consentSource: .companionBYOKSettings))

        let snapshot = await gateway.snapshot()
        let captured = try XCTUnwrap(snapshot)
        XCTAssertEqual(captured.metadata.destination.scope, .localDevice)
        XCTAssertEqual(captured.metadata.providerDisclosure.providerID, "localhost")
    }

    func testGatewayRejectsForgedDestinationOrProviderBeforeTransport() throws {
        let request = try OpenAICompatibleChatClient.urlRequest(
            endpoint: URL(string: "https://api.example.com/v1")!,
            model: "m",
            apiKey: "k",
            system: "s",
            user: "u",
            temperature: 0.3,
            maxTokens: 10)
        let metadata = egressMetadata(
            destination: URL(string: "https://other.example.com/v1/chat/completions")!,
            meetingID: meetingID)

        XCTAssertThrowsError(try URLSessionDataEgressGateway.validate(
            request,
            metadata: metadata)) { error in
            XCTAssertEqual(
                error as? DataEgressGatewayError,
                .invalidMetadata("destination does not match the network request"))
        }

        let providerMetadata = egressMetadata(
            destination: try XCTUnwrap(request.url),
            meetingID: meetingID,
            providerID: "other.example.com")
        XCTAssertThrowsError(try URLSessionDataEgressGateway.validate(
            request,
            metadata: providerMetadata)) { error in
            XCTAssertEqual(
                error as? DataEgressGatewayError,
                .invalidMetadata(
                    "provider disclosure does not match the destination"))
        }
    }

    func testGatewayRejectsNonHTTPDestinationBeforeTransport() throws {
        let destination = URL(fileURLWithPath: "/tmp/meeting-question")
        var request = URLRequest(url: destination)
        request.httpMethod = "POST"
        request.httpBody = Data("question".utf8)
        let metadata = DataEgressRequest(
            operation: .companionKnowledgeAnswer,
            destination: DataEgressDestination(url: destination),
            dataClassification: .meetingQuestionOnly,
            meetingID: meetingID,
            consentSource: .companionBYOKSettings,
            providerDisclosure: DataEgressProviderDisclosure(
                providerID: "BYOK",
                modelID: "m"))

        XCTAssertThrowsError(try URLSessionDataEgressGateway.validate(
            request,
            metadata: metadata)) { error in
            XCTAssertEqual(
                error as? DataEgressGatewayError,
                .invalidMetadata("destination is not an HTTP endpoint"))
        }
    }

    func testGatewayRequiresMeetingIdentityForSettingsConsent() throws {
        let request = try OpenAICompatibleChatClient.urlRequest(
            endpoint: URL(string: "https://api.example.com/v1")!,
            model: "m",
            apiKey: "k",
            system: "s",
            user: "u",
            temperature: 0.3,
            maxTokens: 10)
        let metadata = egressMetadata(
            destination: try XCTUnwrap(request.url),
            meetingID: nil)

        XCTAssertThrowsError(try URLSessionDataEgressGateway.validate(
            request,
            metadata: metadata)) { error in
            XCTAssertEqual(
                error as? DataEgressGatewayError,
                .invalidMetadata(
                    "Settings-approved Companion egress requires a meeting identity"))
        }
    }

    private func egressMetadata(
        destination: URL,
        meetingID: MeetingID?,
        providerID: String = "api.example.com"
    ) -> DataEgressRequest {
        DataEgressRequest(
            operation: .companionKnowledgeAnswer,
            destination: DataEgressDestination(url: destination),
            dataClassification: .meetingQuestionOnly,
            meetingID: meetingID,
            consentSource: .companionBYOKSettings,
            providerDisclosure: DataEgressProviderDisclosure(
                providerID: providerID,
                modelID: "m"))
    }
}

struct TestDataEgressGateway: DataEgressGateway {
    func perform(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) async throws -> DataEgressResponse {
        DataEgressResponse(
            data: Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8),
            statusCode: 200)
    }
}

private actor CapturingDataEgressGateway: DataEgressGateway {
    struct Capture: Sendable {
        let request: URLRequest
        let metadata: DataEgressRequest
    }

    private var capture: Capture?

    func perform(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) async throws -> DataEgressResponse {
        capture = Capture(request: networkRequest, metadata: metadata)
        return DataEgressResponse(
            data: Data(
                #"{"choices":[{"message":{"content":"Use let by default."}}]}"#.utf8),
            statusCode: 200)
    }

    func snapshot() -> Capture? { capture }
}
