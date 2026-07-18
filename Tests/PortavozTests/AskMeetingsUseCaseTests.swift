import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class AskMeetingsUseCaseTests: XCTestCase {
    func testSearchEvidenceAndAnswerShareOneTrimmedWorkflow() async throws {
        let fixture = AskWorkflowFixture()
        let retrieval = AskMeetingRetrievalFake(
            searches: fixture.searches,
            citations: fixture.citations)
        let answering = AskMeetingAnsweringFake(text: "El viernes.")
        let useCase = AskMeetings(retrieval: retrieval, answering: answering)

        let searches = try await useCase.search("  rollout  ", limit: 4)
        let citations = try await useCase.evidence("  rollout  ", limit: 5)
        let answer = try await useCase.answer("  rollout  ", limit: 6)

        XCTAssertEqual(searches, fixture.searches)
        XCTAssertEqual(citations, fixture.citations)
        XCTAssertEqual(answer.question, "rollout")
        XCTAssertEqual(answer.generatedText, "El viernes.")
        XCTAssertEqual(answer.citations, fixture.citations)
        let retrievalCalls = await retrieval.calls
        XCTAssertEqual(retrievalCalls, [
            .search("rollout", 4),
            .retrieve("rollout", 5),
            .retrieve("rollout", 6),
        ])
        let answerCallCount = await answering.callCount
        XCTAssertEqual(answerCallCount, 1)
    }

    func testNoEvidenceSkipsGenerationAndKeepsTypedEmptyAnswer() async throws {
        let retrieval = AskMeetingRetrievalFake(searches: [], citations: [])
        let answering = AskMeetingAnsweringFake(text: "must not be used")
        let useCase = AskMeetings(retrieval: retrieval, answering: answering)

        let result = try await useCase.answer("unknown")

        XCTAssertEqual(result.question, "unknown")
        XCTAssertNil(result.generatedText)
        XCTAssertTrue(result.citations.isEmpty)
        let answerCallCount = await answering.callCount
        XCTAssertEqual(answerCallCount, 0)
    }

    func testGenerationFailureDegradesToEvidenceInsteadOfLosingReceipts() async throws {
        let fixture = AskWorkflowFixture()
        let retrieval = AskMeetingRetrievalFake(
            searches: fixture.searches,
            citations: fixture.citations)
        let answering = AskMeetingAnsweringFake(error: AskWorkflowError.generation)
        let useCase = AskMeetings(retrieval: retrieval, answering: answering)

        let result = try await useCase.answer("rollout")

        XCTAssertNil(result.generatedText)
        XCTAssertEqual(result.citations, fixture.citations)
    }

    func testGenerationCancellationPropagatesInsteadOfMasqueradingAsEvidence() async throws {
        let fixture = AskWorkflowFixture()
        let retrieval = AskMeetingRetrievalFake(
            searches: fixture.searches,
            citations: fixture.citations)
        let answering = AskMeetingAnsweringFake(error: CancellationError())
        let useCase = AskMeetings(retrieval: retrieval, answering: answering)

        do {
            _ = try await useCase.answer("rollout")
            XCTFail("cancellation must leave the application workflow")
        } catch is CancellationError {
            // Expected: presentation owners discard cancelled work by generation.
        }
    }

    func testWhitespaceAndNonPositiveLimitsDoNotEnterCapabilities() async throws {
        let retrieval = AskMeetingRetrievalFake(searches: [], citations: [])
        let answering = AskMeetingAnsweringFake(text: "unused")
        let useCase = AskMeetings(retrieval: retrieval, answering: answering)

        let searches = try await useCase.search("   ")
        let citations = try await useCase.evidence("question", limit: 0)
        XCTAssertTrue(searches.isEmpty)
        XCTAssertTrue(citations.isEmpty)
        let answer = try await useCase.answer("\n")

        XCTAssertTrue(answer.citations.isEmpty)
        let retrievalCalls = await retrieval.calls
        let answerCallCount = await answering.callCount
        XCTAssertTrue(retrievalCalls.isEmpty)
        XCTAssertEqual(answerCallCount, 0)
    }
}

private struct AskWorkflowFixture {
    let meetingID = MeetingID()
    let segmentID = UUID()

    var searches: [AskSearchResult] {
        [AskSearchResult(
            meetingID: meetingID,
            meetingTitle: "Planning",
            segmentID: segmentID,
            snippet: "rollout",
            timestamp: 3)]
    }

    var citations: [AskCitation] {
        [AskCitation(
            segmentID: segmentID,
            meetingID: meetingID,
            meetingTitle: "Planning",
            timestamp: 3,
            text: "El rollout queda para el viernes.")]
    }
}

private actor AskMeetingRetrievalFake: AskMeetingRetrieving {
    enum Call: Equatable {
        case search(String, Int)
        case retrieve(String, Int)
    }

    let searches: [AskSearchResult]
    let citations: [AskCitation]
    private(set) var calls: [Call] = []

    init(searches: [AskSearchResult], citations: [AskCitation]) {
        self.searches = searches
        self.citations = citations
    }

    func search(query: String, limit: Int) -> [AskSearchResult] {
        calls.append(.search(query, limit))
        return searches
    }

    func retrieve(question: String, limit: Int) -> [AskCitation] {
        calls.append(.retrieve(question, limit))
        return citations
    }
}

private actor AskMeetingAnsweringFake: AskMeetingAnswering {
    let text: String?
    let error: Error?
    private(set) var callCount = 0

    init(text: String? = nil, error: Error? = nil) {
        self.text = text
        self.error = error
    }

    func answer(
        question _: String,
        citations _: [AskCitation]
    ) throws -> String? {
        callCount += 1
        if let error { throw error }
        return text
    }
}

private enum AskWorkflowError: Error {
    case generation
}
