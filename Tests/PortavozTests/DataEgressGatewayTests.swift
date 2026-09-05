import Foundation
@testable import IntegrationsKit
@testable import IntelligenceKit
import PortavozCore
import StorageKit
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

    func testGatewayAcceptsOnlyMatchingCanonicalPublishingMetadata() throws {
        let item = ActionItem(text: "Ship the release")
        let requests = [
            (
                try GistPublisher.request(
                    markdown: "# Meeting", filename: "meeting.md",
                    description: "Planning", isPublic: false, token: "token"),
                DataEgressOperation.publishGitHubGist,
                DataEgressClassification.meetingExportDocument,
                DataEgressConsentSource.explicitGistPublish,
                "api.github.com"
            ),
            (
                try GitHubIssuesExporter.request(
                    item: item, meetingTitle: "Planning", ownerName: "Ana",
                    repository: "owner/repo", token: "token"),
                .createGitHubIssue,
                .meetingActionItem,
                .explicitGitHubIssuePublish,
                "api.github.com"
            ),
            (
                try LinearExporter.request(
                    item: item, meetingTitle: "Planning", ownerName: nil,
                    teamID: "TEAM", token: "token"),
                .createLinearIssue,
                .meetingActionItem,
                .explicitLinearIssuePublish,
                "api.linear.app"
            ),
        ]

        for (request, operation, classification, consent, provider) in requests {
            let destination = try XCTUnwrap(request.url)
            let metadata = publishingMetadata(
                operation: operation,
                destination: destination,
                meetingID: meetingID,
                classification: classification,
                consentSource: consent,
                providerID: provider)
            XCTAssertNoThrow(try URLSessionDataEgressGateway.validate(
                request,
                metadata: metadata))
        }
    }

    func testGatewayRejectsForgedPublishingMetadataBeforeTransport() throws {
        let request = try GistPublisher.request(
            markdown: "# Meeting", filename: "meeting.md",
            description: "Planning", isPublic: false, token: "token")
        let destination = try XCTUnwrap(request.url)
        let valid = publishingMetadata(
            operation: .publishGitHubGist,
            destination: destination,
            meetingID: meetingID,
            classification: .meetingExportDocument,
            consentSource: .explicitGistPublish,
            providerID: "api.github.com")
        var getRequest = request
        getRequest.httpMethod = "GET"
        var emptyRequest = request
        emptyRequest.httpBody = Data()

        let forged: [(URLRequest, DataEgressRequest)] = [
            (request, publishingMetadata(
                operation: .createGitHubIssue, destination: destination,
                meetingID: meetingID, classification: .meetingExportDocument,
                consentSource: .explicitGistPublish, providerID: "api.github.com")),
            (request, publishingMetadata(
                operation: .publishGitHubGist, destination: destination,
                meetingID: meetingID, classification: .meetingActionItem,
                consentSource: .explicitGistPublish, providerID: "api.github.com")),
            (request, publishingMetadata(
                operation: .publishGitHubGist, destination: destination,
                meetingID: nil, classification: .meetingExportDocument,
                consentSource: .explicitGistPublish, providerID: "api.github.com")),
            (request, publishingMetadata(
                operation: .publishGitHubGist, destination: destination,
                meetingID: meetingID, classification: .meetingExportDocument,
                consentSource: .explicitGitHubIssuePublish, providerID: "api.github.com")),
            (request, publishingMetadata(
                operation: .publishGitHubGist, destination: destination,
                meetingID: meetingID, classification: .meetingExportDocument,
                consentSource: .explicitGistPublish, providerID: "uploads.github.com")),
            (request, publishingMetadata(
                operation: .publishGitHubGist, destination: destination,
                meetingID: meetingID, classification: .meetingExportDocument,
                consentSource: .explicitGistPublish, providerID: "api.github.com",
                modelID: "not-a-model-operation")),
            (getRequest, valid),
            (emptyRequest, valid),
        ]
        for (forgedRequest, forgedMetadata) in forged {
            XCTAssertThrowsError(try URLSessionDataEgressGateway.validate(
                forgedRequest,
                metadata: forgedMetadata))
        }
    }

    func testGatewayRejectsNonCanonicalGitHubIssueEndpointsBeforeTransport() throws {
        let item = ActionItem(text: "Ship the release")
        let githubRequest = try GitHubIssuesExporter.request(
            item: item, meetingTitle: "Planning", ownerName: nil,
            repository: "owner/repo", token: "token")
        let invalidURLs = [
            "http://api.github.com/repos/owner/repo/issues",
            "https://api.github.com:443/repos/owner/repo/issues",
            "https://api.github.com/repos/owner/repo/issues?milestone=1",
            "https://api.github.com/repos/owner/repo/issues#fragment",
            "https://api.github.com/repos/owner/repo/issues/extra",
            "https://api.github.com/repos//repo/issues",
            "https://api.github.com/repos/%2E%2E/repo/issues",
            "https://api.github.com/repos/owner/repo%2F..%2Fevil/issues",
        ]
        for rawURL in invalidURLs {
            var forged = githubRequest
            let url = try XCTUnwrap(URL(string: rawURL))
            forged.url = url
            let metadata = publishingMetadata(
                operation: .createGitHubIssue,
                destination: url,
                meetingID: meetingID,
                classification: .meetingActionItem,
                consentSource: .explicitGitHubIssuePublish,
                providerID: "api.github.com")
            XCTAssertThrowsError(try URLSessionDataEgressGateway.validate(
                forged,
                metadata: metadata), rawURL)
        }
    }

    func testGatewayRejectsNonCanonicalFixedPublishingEndpointsBeforeTransport() throws {
        let item = ActionItem(text: "Ship the release")
        try assertFixedPublishingEndpointRejected(
            request: GistPublisher.request(
                markdown: "# M", filename: "m.md", description: "M",
                isPublic: false, token: "token"),
            forgedURL: "https://api.github.com/gists?public=true",
            operation: .publishGitHubGist,
            classification: .meetingExportDocument,
            consentSource: .explicitGistPublish,
            providerID: "api.github.com")
        try assertFixedPublishingEndpointRejected(
            request: LinearExporter.request(
                item: item, meetingTitle: "Planning", ownerName: nil,
                teamID: "TEAM", token: "token"),
            forgedURL: "https://api.linear.app/graphql/v2",
            operation: .createLinearIssue,
            classification: .meetingActionItem,
            consentSource: .explicitLinearIssuePublish,
            providerID: "api.linear.app")
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

    func testWebGatewayAcceptsOnlyExactContentFreeGETMetadata() throws {
        let url = URL(string: "http://127.0.0.1:8765/source")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let valid = webMetadata(destination: url)

        XCTAssertNoThrow(try URLSessionDataEgressGateway.validate(
            request,
            metadata: valid))

        var withBody = request
        withBody.httpBody = Data("question or meeting material".utf8)
        let invalidMetadata = [
            DataEgressRequest(
                operation: .webSourceRetrieval,
                destination: DataEgressDestination(url: url),
                dataClassification: .meetingAnswerMaterial,
                meetingID: nil,
                consentSource: .explicitWebAsk,
                providerDisclosure: valid.providerDisclosure),
            DataEgressRequest(
                operation: .webSourceRetrieval,
                destination: DataEgressDestination(url: url),
                dataClassification: .publicWebSourceRequest,
                meetingID: meetingID,
                consentSource: .explicitWebAsk,
                providerDisclosure: valid.providerDisclosure),
            DataEgressRequest(
                operation: .webSourceRetrieval,
                destination: DataEgressDestination(url: url),
                dataClassification: .publicWebSourceRequest,
                meetingID: nil,
                consentSource: .summaryEngineSettings,
                providerDisclosure: valid.providerDisclosure),
            DataEgressRequest(
                operation: .webSourceRetrieval,
                destination: DataEgressDestination(url: url),
                dataClassification: .publicWebSourceRequest,
                meetingID: nil,
                consentSource: .explicitWebAsk,
                providerDisclosure: DataEgressProviderDisclosure(
                    providerID: "127.0.0.1",
                    modelID: "must-stay-nil")),
        ]
        for metadata in invalidMetadata {
            XCTAssertThrowsError(try URLSessionDataEgressGateway.validate(
                request,
                metadata: metadata))
        }
        XCTAssertThrowsError(try URLSessionDataEgressGateway.validate(
            withBody,
            metadata: valid))
        var post = request
        post.httpMethod = "POST"
        XCTAssertThrowsError(try URLSessionDataEgressGateway.validate(
            post,
            metadata: valid))

        let insecureRemote = URL(string: "http://example.com/source")!
        var remoteRequest = URLRequest(url: insecureRemote)
        remoteRequest.httpMethod = "GET"
        XCTAssertThrowsError(try URLSessionDataEgressGateway.validate(
            remoteRequest,
            metadata: webMetadata(destination: insecureRemote)))
    }

    func testWebGatewayStreamsWithinCapAndRejectsFirstExcessByte() async throws {
        let state = ReceiptTransportState.shared
        let recorder = ReceiptRecorderProbe(state: state)
        let session = receiptSession()
        defer { session.invalidateAndCancel(); state.reset() }
        let gateway = URLSessionDataEgressGateway(
            session: session,
            receiptRecorder: recorder)
        let url = URL(string: "http://127.0.0.1:8765/source")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let maximum = 512 * 1_024

        state.reset(
            responseData: Data(repeating: 0x61, count: maximum),
            responseHeaders: [
                "Content-Type": "text/plain",
                "X-Fixture": "bounded",
            ])
        let response = try await gateway.perform(
            request,
            metadata: webMetadata(destination: url))
        XCTAssertEqual(response.data.count, maximum)
        XCTAssertEqual(response.headers["content-type"], "text/plain")
        XCTAssertEqual(response.headers["x-fixture"], "bounded")

        state.reset(responseData: Data(repeating: 0x62, count: maximum + 1))
        await XCTAssertThrowsErrorAsync(try await gateway.perform(
            request,
            metadata: webMetadata(destination: url))) { error in
                XCTAssertEqual(
                    error as? DataEgressGatewayError,
                    .responseTooLarge(
                        actualBytes: maximum + 1,
                        maximumBytes: maximum))
            }
    }

    func testGatewayPersistsContentFreeReceiptBeforeTransport() async throws {
        let state = ReceiptTransportState.shared
        state.reset()
        let recorder = ReceiptRecorderProbe(state: state)
        let session = receiptSession()
        defer { session.invalidateAndCancel(); state.reset() }
        let eventID = DataEgressEventID(rawValue: UUID(
            uuidString: "E6000000-0000-0000-0000-000000000099")!)
        let attemptedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let gateway = URLSessionDataEgressGateway(
            session: session,
            receiptRecorder: recorder,
            now: { attemptedAt },
            makeEventID: { eventID })
        let (request, metadata) = try receiptSummaryRequest()

        let response = try await gateway.perform(request, metadata: metadata)
        let events = await recorder.snapshot()

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(state.snapshot().timeline, ["receipt", "transport"])
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.id, eventID)
        XCTAssertEqual(event.meetingID, meetingID)
        XCTAssertEqual(event.destinationHost, "api.example.com")
        XCTAssertEqual(event.destinationScope, .remote)
        XCTAssertEqual(event.attemptedAt, attemptedAt)
        XCTAssertFalse(event.destinationHost.contains("/v1"))
    }

    func testGatewayPersistsGlobalAskReceiptBeforeLoopbackTransport() async throws {
        let state = ReceiptTransportState.shared
        state.reset()
        let store = try MeetingStore.inMemory()
        let recorder = GlobalAskReceiptRecorderProbe(
            state: state,
            store: store)
        let session = receiptSession()
        defer { session.invalidateAndCancel(); state.reset() }
        let gateway = URLSessionDataEgressGateway(
            session: session,
            receiptRecorder: recorder)
        let endpoint = OllamaService.openAIEndpoint
        let request = try OpenAICompatibleChatCodec.urlRequest(
            endpoint: endpoint,
            model: "qwen-local",
            apiKey: "ollama",
            system: "grounded",
            user: "bounded meeting evidence",
            temperature: 0,
            maxTokens: 500)
        let metadata = DataEgressRequest(
            operation: .askAnswerGeneration,
            destination: DataEgressDestination(
                url: try XCTUnwrap(request.url)),
            dataClassification: .meetingAnswerMaterial,
            meetingID: nil,
            consentSource: .summaryEngineSettings,
            providerDisclosure: DataEgressProviderDisclosure(
                providerID: "localhost",
                modelID: "qwen-local"))

        _ = try await gateway.perform(request, metadata: metadata)

        XCTAssertEqual(state.snapshot().timeline, ["receipt", "transport"])
        let events = try await store.globalDataEgressEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events.first?.meetingID)
        XCTAssertEqual(events.first?.operation, .askAnswerGeneration)
    }

    func testReceiptFailurePreventsTransport() async throws {
        let state = ReceiptTransportState.shared
        state.reset()
        let recorder = ReceiptRecorderProbe(state: state, shouldFail: true)
        let session = receiptSession()
        defer { session.invalidateAndCancel(); state.reset() }
        let gateway = URLSessionDataEgressGateway(
            session: session,
            receiptRecorder: recorder)
        let (request, metadata) = try receiptSummaryRequest()

        do {
            _ = try await gateway.perform(request, metadata: metadata)
            XCTFail("an unreceipted transfer must fail closed")
        } catch {
            XCTAssertEqual(error as? ReceiptRecorderProbe.Failure, .persistence)
        }
        XCTAssertEqual(state.snapshot().timeline, ["receipt"])
        XCTAssertEqual(state.snapshot().requestCount, 0)
    }

    func testFailedTransportStillRetainsAttemptReceipt() async throws {
        let state = ReceiptTransportState.shared
        state.reset(error: URLError(.cannotConnectToHost))
        let recorder = ReceiptRecorderProbe(state: state)
        let session = receiptSession()
        defer { session.invalidateAndCancel(); state.reset() }
        let gateway = URLSessionDataEgressGateway(
            session: session,
            receiptRecorder: recorder)
        let (request, metadata) = try receiptSummaryRequest()

        do {
            _ = try await gateway.perform(request, metadata: metadata)
            XCTFail("the transport fixture must fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
        XCTAssertEqual(state.snapshot().timeline, ["receipt", "transport"])
        let events = await recorder.snapshot()
        XCTAssertEqual(events.count, 1)
    }

    func testStableAttemptIDStopsGistRetryBeforeSecondTransport() async throws {
        let state = ReceiptTransportState.shared
        state.reset(error: URLError(.cannotConnectToHost))
        let store = try MeetingStore.inMemory()
        try await store.save(Meeting(
            id: meetingID,
            title: "Gist duplicate fence",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let session = receiptSession()
        defer { session.invalidateAndCancel(); state.reset() }
        let eventID = DataEgressEventID(rawValue: UUID(
            uuidString: "E6000000-0000-0000-0000-000000000098")!)
        let gateway = URLSessionDataEgressGateway(
            session: session,
            receiptRecorder: store,
            makeEventID: { eventID })
        let request = try GistPublisher.request(
            markdown: "# Exact approved draft",
            filename: "approved.md",
            description: "Approved",
            isPublic: false,
            token: "test-token")
        let metadata = publishingMetadata(
            operation: .publishGitHubGist,
            destination: try XCTUnwrap(request.url),
            meetingID: meetingID,
            classification: .meetingExportDocument,
            consentSource: .explicitGistPublish,
            providerID: "api.github.com")

        await XCTAssertThrowsErrorAsync(
            try await gateway.perform(request, metadata: metadata)) { error in
                XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
            }
        await XCTAssertThrowsErrorAsync(
            try await gateway.perform(request, metadata: metadata)) { error in
                XCTAssertNil(
                    error as? URLError,
                    "the duplicate receipt must fail before URLSession")
            }

        XCTAssertEqual(state.snapshot().requestCount, 1)
        let events = try await store.dataEgressEvents(for: meetingID)
        XCTAssertEqual(events.map(\.id), [eventID])
    }

    func testInvalidMetadataCreatesNeitherReceiptNorTransport() async throws {
        let state = ReceiptTransportState.shared
        state.reset()
        let recorder = ReceiptRecorderProbe(state: state)
        let session = receiptSession()
        defer { session.invalidateAndCancel(); state.reset() }
        let gateway = URLSessionDataEgressGateway(
            session: session,
            receiptRecorder: recorder)
        let (request, metadata) = try receiptSummaryRequest()
        let forged = DataEgressRequest(
            operation: metadata.operation,
            destination: metadata.destination,
            dataClassification: .meetingQuestionOnly,
            meetingID: metadata.meetingID,
            consentSource: metadata.consentSource,
            providerDisclosure: metadata.providerDisclosure)

        do {
            _ = try await gateway.perform(request, metadata: forged)
            XCTFail("forged metadata must fail")
        } catch {
            XCTAssertNotNil(error as? DataEgressGatewayError)
        }
        let events = await recorder.snapshot()
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(state.snapshot().requestCount, 0)
    }

    func testMeetingContentRedirectsAreNeverFollowed() throws {
        let blocker = DataEgressRedirectBlocker()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://api.example.com/v1/chat/completions")!
        let redirected = URLRequest(url: URL(string: "https://collector.example.net/upload")!)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: original,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirected.url!.absoluteString]))
        let task = session.dataTask(with: original)
        let capture = RedirectCompletionCapture()

        blocker.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: redirected
        ) { request in
            capture.record(request)
        }

        let result = capture.snapshot()
        XCTAssertTrue(result.called)
        XCTAssertNil(result.request)
    }

    private func receiptSummaryRequest() throws -> (URLRequest, DataEgressRequest) {
        let request = try OpenAICompatibleChatCodec.urlRequest(
            endpoint: URL(string: "https://api.example.com/v1")!,
            model: "summary-model",
            apiKey: "secret",
            system: "static",
            user: "meeting material",
            temperature: 0.3,
            maxTokens: 100)
        return (
            request,
            summaryMetadata(
                destination: try XCTUnwrap(request.url),
                meetingID: meetingID,
                consentSource: .summaryEngineSettings))
    }

    private func receiptSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReceiptURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func publishingMetadata(
        operation: DataEgressOperation,
        destination: URL,
        meetingID: MeetingID?,
        classification: DataEgressClassification,
        consentSource: DataEgressConsentSource,
        providerID: String,
        modelID: String? = nil
    ) -> DataEgressRequest {
        DataEgressRequest(
            operation: operation,
            destination: DataEgressDestination(url: destination),
            dataClassification: classification,
            meetingID: meetingID,
            consentSource: consentSource,
            providerDisclosure: DataEgressProviderDisclosure(
                providerID: providerID,
                modelID: modelID))
    }

    private func assertFixedPublishingEndpointRejected(
        request: URLRequest,
        forgedURL: String,
        operation: DataEgressOperation,
        classification: DataEgressClassification,
        consentSource: DataEgressConsentSource,
        providerID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var forged = request
        let destination = try XCTUnwrap(URL(string: forgedURL), file: file, line: line)
        forged.url = destination
        let metadata = publishingMetadata(
            operation: operation,
            destination: destination,
            meetingID: meetingID,
            classification: classification,
            consentSource: consentSource,
            providerID: providerID)
        XCTAssertThrowsError(
            try URLSessionDataEgressGateway.validate(forged, metadata: metadata),
            file: file,
            line: line)
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

    private func webMetadata(destination: URL) -> DataEgressRequest {
        DataEgressRequest(
            operation: .webSourceRetrieval,
            destination: DataEgressDestination(url: destination),
            dataClassification: .publicWebSourceRequest,
            meetingID: nil,
            consentSource: .explicitWebAsk,
            providerDisclosure: DataEgressProviderDisclosure(
                providerID: destination.host ?? ""))
    }
}

private final class ReceiptTransportState: @unchecked Sendable {
    static let shared = ReceiptTransportState()

    private let lock = NSLock()
    private var timeline: [String] = []
    private var requestCount = 0
    private var error: Error?
    private var responseData = Data(#"{"ok":true}"#.utf8)
    private var responseHeaders = ["Content-Type": "application/json"]

    func reset(
        error: Error? = nil,
        responseData: Data = Data(#"{"ok":true}"#.utf8),
        responseHeaders: [String: String] = [
            "Content-Type": "application/json",
        ]
    ) {
        lock.lock()
        timeline = []
        requestCount = 0
        self.error = error
        self.responseData = responseData
        self.responseHeaders = responseHeaders
        lock.unlock()
    }

    func appendReceipt() {
        lock.lock()
        timeline.append("receipt")
        lock.unlock()
    }

    func beginTransport() -> Error? {
        lock.lock()
        timeline.append("transport")
        requestCount += 1
        let error = error
        lock.unlock()
        return error
    }

    func snapshot() -> (timeline: [String], requestCount: Int) {
        lock.lock()
        let snapshot = (timeline, requestCount)
        lock.unlock()
        return snapshot
    }

    func responseFixture() -> (data: Data, headers: [String: String]) {
        lock.lock()
        let fixture = (responseData, responseHeaders)
        lock.unlock()
        return fixture
    }
}

private final class RedirectCompletionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    private var called = false

    func record(_ request: URLRequest?) {
        lock.lock()
        self.request = request
        called = true
        lock.unlock()
    }

    func snapshot() -> (request: URLRequest?, called: Bool) {
        lock.lock()
        let snapshot = (request, called)
        lock.unlock()
        return snapshot
    }
}

private final class ReceiptURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let error = ReceiptTransportState.shared.beginTransport() {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let fixture = ReceiptTransportState.shared.responseFixture()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: fixture.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor ReceiptRecorderProbe: DataEgressEventRecorder {
    enum Failure: Error, Equatable { case persistence }

    private let state: ReceiptTransportState
    private let shouldFail: Bool
    private var events: [DataEgressEvent] = []

    init(state: ReceiptTransportState, shouldFail: Bool = false) {
        self.state = state
        self.shouldFail = shouldFail
    }

    func recordDataEgressEvent(_ event: DataEgressEvent) throws {
        state.appendReceipt()
        if shouldFail { throw Failure.persistence }
        events.append(event)
    }

    func snapshot() -> [DataEgressEvent] { events }
}

private actor GlobalAskReceiptRecorderProbe: DataEgressEventRecorder {
    let state: ReceiptTransportState
    let store: MeetingStore

    init(state: ReceiptTransportState, store: MeetingStore) {
        self.state = state
        self.store = store
    }

    func recordDataEgressEvent(_ event: DataEgressEvent) async throws {
        try await store.recordDataEgressEvent(event)
        state.appendReceipt()
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

actor CapturingDataEgressGateway: DataEgressGateway {
    struct Capture: Sendable {
        let request: URLRequest
        let metadata: DataEgressRequest
    }

    private let responseData: Data
    private let statusCode: Int
    private var capture: Capture?

    init(
        responseData: Data = Data(
            #"{"choices":[{"message":{"content":"Use let by default."}}]}"#.utf8),
        statusCode: Int = 200
    ) {
        self.responseData = responseData
        self.statusCode = statusCode
    }

    func perform(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) async throws -> DataEgressResponse {
        capture = Capture(request: networkRequest, metadata: metadata)
        return DataEgressResponse(
            data: responseData,
            statusCode: statusCode)
    }

    func snapshot() -> Capture? { capture }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (any Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
