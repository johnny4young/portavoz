import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class AskPresentationModelTests: XCTestCase {
    func testFullAskOwnsDraftAnswerAndEvidenceFallbackPresentation() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = AskModel(client: client)

        model.updateDraft("  presupuesto  ")
        model.submit()
        try await waitUntil { client.answerRequests == ["presupuesto"] }
        client.completeAnswer(
            "presupuesto",
            with: AskMeetingAnswer(
                question: "presupuesto",
                generatedText: nil,
                citations: [fixture.citation]))
        try await waitUntil { model.state.exchanges.count == 1 }

        XCTAssertEqual(model.state.draft, "")
        XCTAssertFalse(model.state.isAsking)
        XCTAssertEqual(model.state.exchanges.first?.question, "presupuesto")
        XCTAssertEqual(
            model.state.exchanges.first?.answer,
            L10n.text("Closest passages from your meetings:"))
        XCTAssertEqual(model.state.exchanges.first?.citations, [fixture.citation])
    }

    func testFullAskPublishesProgressiveEvidenceThenFencesFinalAnswer() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = AskModel(client: client)

        model.updateDraft("presupuesto")
        model.submit()
        XCTAssertEqual(model.state.pendingPhase, .findingEvidence)
        try await waitUntil { client.answerRequests == ["presupuesto"] }

        await client.publishEvidence(
            "presupuesto",
            update: AskEvidenceUpdate(
                phase: .lexical,
                citations: [fixture.citation]))
        try await waitUntil { model.state.pendingPhase == .refiningEvidence }
        XCTAssertEqual(model.state.pendingCitations, [fixture.citation])

        await client.publishEvidence(
            "presupuesto",
            update: AskEvidenceUpdate(
                phase: .fused,
                citations: [fixture.citation]))
        try await waitUntil { model.state.pendingPhase == .generatingAnswer }

        client.completeAnswer(
            "presupuesto",
            with: AskMeetingAnswer(
                question: "presupuesto",
                generatedText: "El viernes.",
                citations: [fixture.citation]))
        try await waitUntil { model.state.exchanges.count == 1 }

        XCTAssertFalse(model.state.isAsking)
        XCTAssertNil(model.state.pendingQuestion)
        XCTAssertNil(model.state.pendingPhase)
        XCTAssertEqual(model.state.pendingCitations, [])
        XCTAssertEqual(model.state.exchanges.first?.answer, "El viernes.")
    }

    func testFullAskCancellationRejectsLateProgressAndCompletion() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = AskModel(client: client)

        model.updateDraft("old")
        model.submit()
        try await waitUntil { client.answerRequests == ["old"] }
        await client.publishEvidence(
            "old",
            update: AskEvidenceUpdate(
                phase: .lexical,
                citations: [fixture.citation]))
        try await waitUntil { model.state.pendingPhase == .refiningEvidence }

        model.cancelPendingAnswer()
        await client.publishEvidence(
            "old",
            update: AskEvidenceUpdate(
                phase: .fused,
                citations: [fixture.citation]))
        client.completeAnswer(
            "old",
            with: AskMeetingAnswer(
                question: "old",
                generatedText: "stale",
                citations: [fixture.citation]))
        await Task.yield()

        XCTAssertFalse(model.state.isAsking)
        XCTAssertNil(model.state.pendingQuestion)
        XCTAssertNil(model.state.pendingPhase)
        XCTAssertTrue(model.state.pendingCitations.isEmpty)
        XCTAssertTrue(model.state.exchanges.isEmpty)
    }

    func testPaletteResetPreventsClosedGenerationFromPublishingIntoReopen() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = CommandPaletteModel(client: client)

        model.updateQuery("old")
        try await waitUntil { client.searchRequests.contains("old") }
        model.reset()
        model.updateQuery("new")
        try await waitUntil { client.searchRequests.contains("new") }

        client.completeSearch("old", with: [fixture.oldHit])
        client.completeSearch("new", with: [fixture.newHit])
        try await waitUntil { model.state.hits == [fixture.newHit] }

        model.submit()
        try await waitUntil { client.answerRequests.contains("new") }
        model.reset()
        model.updateQuery("newer")
        try await waitUntil { client.searchRequests.contains("newer") }
        client.completeAnswer(
            "new",
            with: AskMeetingAnswer(
                question: "new",
                generatedText: "stale",
                citations: [fixture.citation]))
        client.completeSearch("newer", with: [fixture.newerHit])
        try await waitUntil { model.state.hits == [fixture.newerHit] }

        XCTAssertNil(model.state.answer)
        XCTAssertFalse(model.state.isAnswering)
        XCTAssertEqual(model.state.query, "newer")
    }

    /// SwiftUI can deliver a trailing text update after `onSubmit` — coalesced
    /// typing, an IME commit, a re-render with the same value. Treating that as
    /// a new query cancelled the answer already running for it, leaving the
    /// palette showing hits, no answer, and nothing to restart it.
    func testAnEchoedQueryDoesNotCancelTheAnswerRunningForIt() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = CommandPaletteModel(client: client)

        model.updateQuery("rollout")
        try await waitUntil { client.searchRequests.contains("rollout") }
        client.completeSearch("rollout", with: [fixture.newHit])
        model.submit()
        try await waitUntil { client.answerRequests.contains("rollout") }

        // The same text arrives again while the answer is in flight.
        model.updateQuery("rollout")

        client.completeAnswer(
            "rollout",
            with: AskMeetingAnswer(
                question: "rollout",
                generatedText: "El viernes.",
                citations: [fixture.citation]))
        try await waitUntil { model.state.answer != nil }
        XCTAssertEqual(model.state.answer?.text, "El viernes.")
        XCTAssertFalse(model.state.isAnswering)
    }

    /// `isAnswering` gates `submit`, so a palette that leaked it would refuse
    /// every further Enter. Characterization: this pins the property rather
    /// than a fix — the behaviour already held before the defer that now
    /// guarantees it.
    func testAnAnswerThatFailsStillLetsTheUserAskAgain() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = CommandPaletteModel(client: client)

        model.updateQuery("rollout")
        try await waitUntil { client.searchRequests.contains("rollout") }
        client.completeSearch("rollout", with: [fixture.newHit])
        model.submit()
        try await waitUntil { client.answerRequests.contains("rollout") }

        // The request fails outright rather than answering.
        client.failAnswer("rollout")
        try await waitUntil { !model.state.isAnswering }

        // Enter works again, on the same question.
        model.submit()
        try await waitUntil { client.answerRequests.filter { $0 == "rollout" }.count == 2 }
        client.completeAnswer(
            "rollout",
            with: AskMeetingAnswer(
                question: "rollout",
                generatedText: "El viernes.",
                citations: [fixture.citation]))
        try await waitUntil { model.state.answer?.text == "El viernes." }
    }

    func testPaletteMarkdownKeepsQuestionAnswerAndReceipts() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = CommandPaletteModel(client: client)

        model.updateQuery("rollout")
        try await waitUntil { client.searchRequests.contains("rollout") }
        client.completeSearch("rollout", with: [fixture.newHit])
        model.submit()
        try await waitUntil { client.answerRequests.contains("rollout") }
        client.completeAnswer(
            "rollout",
            with: AskMeetingAnswer(
                question: "rollout",
                generatedText: "El viernes.",
                citations: [fixture.citation]))
        try await waitUntil { model.state.answer != nil }

        XCTAssertEqual(
            model.markdownAnswer(),
            "> rollout\n\nEl viernes.\n\n- Test meeting · 00:03")
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw AskPresentationTestError.timeout }
            await Task.yield()
        }
    }
}

private struct AskPresentationFixture {
    let meetingID = MeetingID()
    let oldHit: AskSearchResult
    let newHit: AskSearchResult
    let newerHit: AskSearchResult
    let citation: AskCitation

    init() {
        oldHit = AskSearchResult(
            meetingID: meetingID,
            meetingTitle: "Old",
            segmentID: UUID(),
            snippet: "old",
            timestamp: 1)
        newHit = AskSearchResult(
            meetingID: meetingID,
            meetingTitle: "New",
            segmentID: UUID(),
            snippet: "new",
            timestamp: 2)
        newerHit = AskSearchResult(
            meetingID: meetingID,
            meetingTitle: "Newer",
            segmentID: UUID(),
            snippet: "newer",
            timestamp: 4)
        citation = AskCitation(
            segmentID: UUID(),
            meetingID: meetingID,
            meetingTitle: "Test meeting",
            timestamp: 3,
            text: "El rollout queda para el viernes.")
    }
}

@MainActor
private final class ControlledAskModelClient: AskModelClient {
    private(set) var searchRequests: [String] = []
    private(set) var answerRequests: [String] = []
    private var searchContinuations: [String: CheckedContinuation<[AskSearchResult], Error>] = [:]
    private var answerContinuations: [String: CheckedContinuation<AskMeetingAnswer, Error>] = [:]
    private var evidenceReceivers: [String: AskEvidenceReceiver] = [:]

    func searchAskMeetings(
        _ query: String,
        limit _: Int
    ) async throws -> [AskSearchResult] {
        searchRequests.append(query)
        return try await withCheckedThrowingContinuation { continuation in
            searchContinuations[query] = continuation
        }
    }

    func answerAskMeetings(
        _ question: String,
        limit _: Int
    ) async throws -> AskMeetingAnswer {
        answerRequests.append(question)
        return try await withCheckedThrowingContinuation { continuation in
            answerContinuations[question] = continuation
        }
    }

    func answerAskMeetings(
        _ question: String,
        limit _: Int,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> AskMeetingAnswer {
        answerRequests.append(question)
        evidenceReceivers[question] = onEvidence
        return try await withCheckedThrowingContinuation { continuation in
            answerContinuations[question] = continuation
        }
    }

    func completeSearch(_ query: String, with hits: [AskSearchResult]) {
        searchContinuations.removeValue(forKey: query)?.resume(returning: hits)
    }

    func completeAnswer(_ question: String, with answer: AskMeetingAnswer) {
        evidenceReceivers.removeValue(forKey: question)
        answerContinuations.removeValue(forKey: question)?.resume(returning: answer)
    }

    func failAnswer(_ question: String) {
        evidenceReceivers.removeValue(forKey: question)
        answerContinuations.removeValue(forKey: question)?
            .resume(throwing: AskPresentationTestError.refused)
    }

    func publishEvidence(
        _ question: String,
        update: AskEvidenceUpdate
    ) async {
        await evidenceReceivers[question]?(update)
    }
}

private enum AskPresentationTestError: Error {
    case timeout
    case refused
}
