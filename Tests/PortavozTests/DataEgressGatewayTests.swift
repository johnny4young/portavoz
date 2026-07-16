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

    func testSummaryProviderRoutesCompleteMaterialWithRemoteMetadata() async throws {
        let structured = #"{"overview":"Listo","sections":[],"actionItems":[]}"#
        let response = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": structured]]]
        ])
        let gateway = CapturingDataEgressGateway(responseData: response)
        let provider = OpenAICompatibleSummaryProvider(
            endpoint: URL(string: "https://api.example.com/v1")!,
            model: "summary-model",
            apiKey: "secret",
            gateway: gateway)
        let speaker = Speaker(meetingID: meetingID, label: "S1", displayName: "Ana")
        let request = SummaryRequest(
            meetingID: meetingID,
            segments: [
                TranscriptSegment(
                    meetingID: meetingID,
                    speakerID: speaker.id,
                    channel: .system,
                    text: "El lanzamiento será el viernes.",
                    startTime: 0,
                    endTime: 3)
            ],
            speakers: [speaker],
            recipe: .general,
            targetLanguage: "es",
            glossary: ["deploy"],
            contextItems: [
                ContextItem(
                    meetingID: meetingID,
                    kind: .note,
                    content: "Confirmar el rollout",
                    timestamp: 2)
            ])

        let draft = try await provider.summarize(request)

        XCTAssertEqual(draft.markdown, "Listo")
        let snapshot = await gateway.snapshot()
        let captured = try XCTUnwrap(snapshot)
        XCTAssertEqual(captured.metadata.operation, .summaryGeneration)
        XCTAssertEqual(captured.metadata.destination.scope, .remote)
        XCTAssertEqual(captured.metadata.dataClassification, .meetingSummaryMaterial)
        XCTAssertEqual(captured.metadata.meetingID, meetingID)
        XCTAssertEqual(captured.metadata.consentSource, .explicitSummaryProvider)
        XCTAssertEqual(captured.metadata.providerDisclosure.providerID, "api.example.com")
        XCTAssertEqual(captured.metadata.providerDisclosure.modelID, "summary-model")
        XCTAssertNoThrow(try URLSessionDataEgressGateway.validate(
            captured.request,
            metadata: captured.metadata))

        let body = try XCTUnwrap(captured.request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        let transferred = messages.compactMap { $0["content"] }.joined(separator: "\n")
        for material in ["El lanzamiento será el viernes.", "Confirmar el rollout", "deploy"] {
            XCTAssertTrue(transferred.contains(material), material)
        }
    }

    func testSummaryClientMarksConfiguredOllamaAsLocal() async throws {
        let gateway = CapturingDataEgressGateway()
        let client = OpenAICompatibleSummaryClient(
            endpoint: URL(string: "http://localhost:11434/v1")!,
            model: "qwen-local",
            apiKey: "ollama",
            gateway: gateway,
            consentSource: .summaryEngineSettings)

        _ = try await client.completeSummary(
            system: "Static summary instructions",
            user: "Meeting material",
            meetingID: meetingID)

        let snapshot = await gateway.snapshot()
        let captured = try XCTUnwrap(snapshot)
        XCTAssertEqual(captured.metadata.destination.scope, .localDevice)
        XCTAssertEqual(captured.metadata.consentSource, .summaryEngineSettings)
        XCTAssertNoThrow(try URLSessionDataEgressGateway.validate(
            captured.request,
            metadata: captured.metadata))
    }

    func testGatewayRejectsSummaryWithoutMeetingOrSummaryConsent() throws {
        let request = try OpenAICompatibleChatCodec.urlRequest(
            endpoint: URL(string: "https://api.example.com/v1")!,
            model: "m",
            apiKey: "k",
            system: "s",
            user: "u",
            temperature: 0.3,
            maxTokens: nil)
        let destination = try XCTUnwrap(request.url)
        let missingMeeting = summaryMetadata(
            destination: destination,
            meetingID: nil,
            consentSource: .explicitSummaryProvider)
        XCTAssertThrowsError(try URLSessionDataEgressGateway.validate(
            request,
            metadata: missingMeeting)) { error in
            XCTAssertEqual(
                error as? DataEgressGatewayError,
                .invalidMetadata("Summary egress requires a meeting identity"))
        }

        let wrongConsent = summaryMetadata(
            destination: destination,
            meetingID: meetingID,
            consentSource: .explicitCompanionClient)
        XCTAssertThrowsError(try URLSessionDataEgressGateway.validate(
            request,
            metadata: wrongConsent)) { error in
            XCTAssertEqual(
                error as? DataEgressGatewayError,
                .invalidMetadata("Summary egress requires summary-specific consent"))
        }
    }

    func testGatewayRejectsForgedDestinationOrProviderBeforeTransport() throws {
        let request = try OpenAICompatibleChatCodec.urlRequest(
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
        let request = try OpenAICompatibleChatCodec.urlRequest(
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

        let wrongConsent = DataEgressRequest(
            operation: metadata.operation,
            destination: metadata.destination,
            dataClassification: metadata.dataClassification,
            meetingID: meetingID,
            consentSource: .explicitSummaryProvider,
            providerDisclosure: metadata.providerDisclosure)
        XCTAssertThrowsError(try URLSessionDataEgressGateway.validate(
            request,
            metadata: wrongConsent)) { error in
            XCTAssertEqual(
                error as? DataEgressGatewayError,
                .invalidMetadata("Companion egress requires Companion-specific consent"))
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

    private func summaryMetadata(
        destination: URL,
        meetingID: MeetingID?,
        consentSource: DataEgressConsentSource
    ) -> DataEgressRequest {
        DataEgressRequest(
            operation: .summaryGeneration,
            destination: DataEgressDestination(url: destination),
            dataClassification: .meetingSummaryMaterial,
            meetingID: meetingID,
            consentSource: consentSource,
            providerDisclosure: DataEgressProviderDisclosure(
                providerID: "api.example.com",
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

    private let responseData: Data
    private var capture: Capture?

    init(responseData: Data = Data(
        #"{"choices":[{"message":{"content":"Use let by default."}}]}"#.utf8
    )) {
        self.responseData = responseData
    }

    func perform(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) async throws -> DataEgressResponse {
        capture = Capture(request: networkRequest, metadata: metadata)
        return DataEgressResponse(
            data: responseData,
            statusCode: 200)
    }

    func snapshot() -> Capture? { capture }
}
