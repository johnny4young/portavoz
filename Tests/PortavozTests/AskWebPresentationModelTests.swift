import ApplicationKit
import PortavozCore
@testable import portavoz_app
import XCTest

@MainActor
final class AskWebPresentationModelTests: XCTestCase {
    func testConsentIsBoundToExactQuestionAndSource() throws {
        let model = AskModel(
            client: WebModelClientStub(),
            webSourcePolicy: .loopbackFixture)
        model.selectSourceMode(.web)
        model.updateDraft("When?")
        model.updateWebSourceDraft("http://127.0.0.1:9000/source")
        XCTAssertTrue(model.canApproveWebConsent)

        model.setWebConsentApproved(true)
        XCTAssertTrue(model.state.webConsentApproved)
        model.updateDraft("When exactly?")
        XCTAssertFalse(model.state.webConsentApproved)
        model.setWebConsentApproved(true)
        model.updateWebSourceDraft("http://127.0.0.1:9000/other")
        XCTAssertFalse(model.state.webConsentApproved)
    }

    func testProductionPresentationRejectsHTTPAndLoopbackSources() {
        let model = AskModel(client: WebModelClientStub())
        model.selectSourceMode(.web)
        model.updateDraft("When?")

        for source in [
            "http://example.com/source",
            "https://127.0.0.1/source",
            "https://printer.local/source",
            "https://example.com:8443/source",
            "https://user:password@example.com/source",
            "https://example.com/source#fragment",
        ] {
            model.updateWebSourceDraft(source)
            XCTAssertFalse(model.canApproveWebConsent)
            model.setWebConsentApproved(true)
            XCTAssertFalse(model.state.webConsentApproved)
        }
    }

    func testWebSubmitConsumesConsentAndPublishesTypedEvidence() async throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:9000/source"))
        let citation = webCitation(url)
        let client = WebModelClientStub(webResult: AskWebAnswer(
            question: "When?",
            generatedText: "Harbor launches [1].",
            citations: [citation],
            sourceFailures: [],
            generationOutcome: .generated))
        let model = AskModel(
            client: client,
            webSourcePolicy: .loopbackFixture)
        model.selectSourceMode(.web)
        model.updateDraft("When?")
        model.updateWebSourceDraft(url.absoluteString)
        model.setWebConsentApproved(true)

        model.submit()
        XCTAssertFalse(model.state.webConsentApproved)
        XCTAssertTrue(model.state.isAsking)
        XCTAssertEqual(model.state.pendingSource, .web(host: "127.0.0.1"))
        let completed = await eventually { !model.state.isAsking }
        XCTAssertTrue(completed)

        XCTAssertEqual(client.webCallCount, 1)
        XCTAssertEqual(client.localCallCount, 0)
        XCTAssertEqual(model.state.exchanges.count, 1)
        let exchange = try XCTUnwrap(model.state.exchanges.first)
        XCTAssertEqual(exchange.source, .web(host: "127.0.0.1"))
        XCTAssertEqual(exchange.citations, [])
        XCTAssertEqual(exchange.webCitations, [citation])
        XCTAssertEqual(exchange.answer, "Harbor launches [1].")
    }

    func testChangingSourceCancelsPendingWebRequest() async throws {
        let client = WebModelClientStub(blocksWeb: true)
        let model = AskModel(
            client: client,
            webSourcePolicy: .loopbackFixture)
        model.selectSourceMode(.web)
        model.updateDraft("When?")
        model.updateWebSourceDraft("http://127.0.0.1:9000/source")
        model.setWebConsentApproved(true)
        model.submit()
        let started = await eventually { client.webCallCount == 1 }
        XCTAssertTrue(started)

        model.selectSourceMode(.library)
        XCTAssertFalse(model.state.isAsking)
        XCTAssertTrue(model.state.exchanges.isEmpty)
        let cancelled = await eventually { client.webCancellationCount == 1 }
        XCTAssertTrue(cancelled)
    }

    func testEditingExactWebAddressCancelsItsPendingRequest() async throws {
        let client = WebModelClientStub(blocksWeb: true)
        let model = AskModel(
            client: client,
            webSourcePolicy: .loopbackFixture)
        model.selectSourceMode(.web)
        model.updateDraft("When?")
        model.updateWebSourceDraft("http://127.0.0.1:9000/source")
        model.setWebConsentApproved(true)
        model.submit()
        let started = await eventually { client.webCallCount == 1 }
        XCTAssertTrue(started)

        model.updateWebSourceDraft("http://127.0.0.1:9000/other")

        XCTAssertFalse(model.state.webConsentApproved)
        XCTAssertFalse(model.state.isAsking)
        XCTAssertTrue(model.state.exchanges.isEmpty)
        let cancelled = await eventually { client.webCancellationCount == 1 }
        XCTAssertTrue(cancelled)
    }

    private func webCitation(_ url: URL) -> AskWebCitation {
        AskWebCitation(
            url: url,
            title: "Source",
            observedDate: Date(timeIntervalSince1970: 100),
            observedDateKind: .published,
            retrievedAt: Date(timeIntervalSince1970: 200),
            freshness: .recent,
            text: "Harbor launches.",
            isExcerptTruncated: false)
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

@MainActor
private final class WebModelClientStub: AskModelClient {
    private let webResult: AskWebAnswer?
    private let blocksWeb: Bool
    private(set) var webCallCount = 0
    private(set) var webCancellationCount = 0
    private(set) var localCallCount = 0

    init(webResult: AskWebAnswer? = nil, blocksWeb: Bool = false) {
        self.webResult = webResult
        self.blocksWeb = blocksWeb
    }

    func searchAskMeetings(
        _ query: String,
        source: AskSourceScope,
        limit: Int
    ) async throws -> [AskSearchResult] {
        []
    }

    func answerAskMeetings(
        _ question: String,
        source: AskSourceScope,
        limit: Int
    ) async throws -> AskMeetingAnswer {
        localCallCount += 1
        return AskMeetingAnswer(
            question: question,
            generatedText: nil,
            citations: [])
    }

    func answerAskWeb(
        _ request: AskWebRequest,
        onEvidence: @escaping AskWebEvidenceReceiver,
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> AskWebAnswer {
        webCallCount += 1
        if blocksWeb {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                webCancellationCount += 1
                throw CancellationError()
            }
        }
        let result = webResult ?? AskWebAnswer(
            question: request.question,
            generatedText: nil,
            citations: [],
            sourceFailures: [],
            generationOutcome: .notRequested)
        await onEvidence(AskWebEvidenceUpdate(
            citations: result.citations,
            sourceFailures: result.sourceFailures))
        if let text = result.generatedText {
            await onAnswer(AskAnswerUpdate(text: text))
        }
        return result
    }
}
