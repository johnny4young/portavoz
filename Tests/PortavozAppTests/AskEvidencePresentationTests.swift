import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class AskEvidencePresentationTests: XCTestCase {
    private let citation = AskCitation(
        segmentID: UUID(), meetingID: MeetingID(), meetingTitle: "Sprint demo",
        timestamp: 138, text: "Yo me llevo la migración de los dashboards.")

    private func answer(_ question: String, generated: String? = "You own it [1].") -> AskMeetingAnswer {
        AskMeetingAnswer(question: question, generatedText: generated, citations: [citation])
    }

    func testAnsweredExchangeCarriesEvidenceTimingThenFollowUps() async throws {
        let client = EvidenceAskClient()
        client.answers["kepler"] = answer("kepler")
        let model = AskModel(client: client)

        model.updateDraft("kepler")
        model.submit()
        try await waitUntil { model.state.exchanges.count == 1 }

        let exchange = try XCTUnwrap(model.state.exchanges.first)
        XCTAssertNotNil(exchange.answeredIn)
        XCTAssertEqual(exchange.followUps, [])
        try await waitUntil { model.state.exchanges.first?.evidence != nil }
        XCTAssertEqual(model.state.exchanges.first?.evidence, client.evidence)
        XCTAssertEqual(client.evidenceRequests.first?.answer, "You own it [1].")
        XCTAssertEqual(client.evidenceRequests.first?.citations, [citation])

        try await waitUntil { client.followUpRequests == ["kepler"] }
        client.resolveFollowUps(at: 0, ["Who can give Nora access?", "What else is due Friday?"])
        try await waitUntil { !(model.state.exchanges.first?.followUps.isEmpty ?? true) }
        XCTAssertEqual(
            model.state.exchanges.first?.followUps,
            ["Who can give Nora access?", "What else is due Friday?"])
    }

    func testEvidenceFailureKeepsTheAnswerAndUngeneratedAnswersGetNoFollowUps() async throws {
        let client = EvidenceAskClient()
        client.evidenceFails = true
        client.answers["kepler"] = answer("kepler", generated: nil)
        let model = AskModel(client: client)

        client.answers["next"] = answer("next")
        model.updateDraft("kepler")
        model.submit()
        try await waitUntil { client.evidenceRequests.count == 1 }
        try await waitUntil { model.state.exchanges.count == 1 }

        XCTAssertNil(model.state.exchanges.first?.evidence)
        XCTAssertEqual(model.state.exchanges.first?.citations, [citation])
        // Requests keep order, so a follow-up for the first answer would precede this one.
        model.updateDraft("next")
        model.submit()
        try await waitUntil { !client.followUpRequests.isEmpty }
        XCTAssertEqual(client.followUpRequests, ["next"])
    }

    func testASlowEvidenceReadNeverHoldsTheAnswerBack() async throws {
        let client = EvidenceAskClient()
        client.evidenceHangs = true
        client.answers["kepler"] = answer("kepler")
        let model = AskModel(client: client)

        model.updateDraft("kepler")
        model.submit()
        try await waitUntil { model.state.exchanges.count == 1 }

        XCTAssertFalse(model.state.isAsking)
        XCTAssertNil(model.state.exchanges.first?.evidence)
        try await waitUntil { client.followUpRequests == ["kepler"] }
        client.resolveEvidence()
        try await waitUntil { model.state.exchanges.first?.evidence != nil }
    }

    func testAFollowUpIsAskedFromTheMeetingThatOfferedIt() async throws {
        let client = EvidenceAskClient()
        let meeting = AskSourceMeetingOption(id: citation.meetingID, title: "Sprint demo", startedAt: Date())
        client.sourceMeetings = [meeting]
        client.answers["kepler"] = answer("kepler")
        client.answers["Who can give Nora access?"] = answer("Who can give Nora access?")
        let model = AskModel(client: client)
        model.selectSourceMode(.meeting)
        try await waitUntil { model.state.sourceCatalogState == .loaded }
        model.selectSourceMeeting(meeting.id)

        model.updateDraft("kepler")
        model.submit()
        try await waitUntil { client.followUpRequests == ["kepler"] }
        client.resolveFollowUps(at: 0, ["Who can give Nora access?", "What else is due Friday?"])
        try await waitUntil { !(model.state.exchanges.first?.followUps.isEmpty ?? true) }
        model.selectSourceMode(.notes)

        model.askFollowUp("Who can give Nora access?")
        try await waitUntil { model.state.exchanges.count == 2 }
        XCTAssertEqual(model.state.sourceMode, .meeting)
        XCTAssertEqual(client.answerSources, [.meeting(meeting.id), .meeting(meeting.id)])
    }

    func testANewQuestionCancelsPendingFollowUpsAndAFollowUpAsksFromTheSameSource() async throws {
        let client = EvidenceAskClient()
        client.answers["kepler"] = answer("kepler")
        client.answers["Who can give Nora access?"] = answer("Who can give Nora access?")
        let model = AskModel(client: client)

        model.updateDraft("kepler")
        model.submit()
        try await waitUntil { client.followUpRequests == ["kepler"] }

        model.askFollowUp("Who can give Nora access?")
        try await waitUntil { client.followUpRequests.count == 2 }
        XCTAssertEqual(model.state.exchanges.count, 2)
        XCTAssertEqual(client.answerSources, [.library, .library])
        client.resolveFollowUps(at: 0, ["Late one?", "Late two?"])
        try await waitUntil { client.cancelledFollowUps == [0] }
        client.resolveFollowUps(at: 1, ["What else is due Friday?", "Draft a status note"])
        try await waitUntil { !(model.state.exchanges.last?.followUps.isEmpty ?? true) }
        XCTAssertEqual(model.state.exchanges.first?.followUps, [])
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw EvidenceTestError.timeout }
            await Task.yield()
        }
    }
}

private enum EvidenceTestError: Error {
    case timeout
    case refused
}

@MainActor
private final class EvidenceAskClient: AskModelClient {
    var answers: [String: AskMeetingAnswer] = [:]
    var evidenceFails = false
    var evidenceHangs = false
    var sourceMeetings: [AskSourceMeetingOption] = []
    private var evidenceContinuation: CheckedContinuation<Void, Never>?
    let evidence = AskEvidence.empty
    private(set) var answerSources: [AskSourceScope] = []
    private(set) var evidenceRequests: [(citations: [AskCitation], answer: String?)] = []
    private(set) var followUpRequests: [String] = []
    private(set) var cancelledFollowUps: [Int] = []
    private var followUpContinuations: [Int: CheckedContinuation<[String], Never>] = [:]

    func searchAskMeetings(_: String, source _: AskSourceScope, limit _: Int) async throws -> [AskSearchResult] {
        []
    }

    func answerAskMeetings(_ question: String, source: AskSourceScope, limit _: Int) async throws -> AskMeetingAnswer {
        answerSources.append(source)
        guard let answer = answers[question] else { throw EvidenceTestError.refused }
        return answer
    }

    func loadAskEvidence(_ citations: [AskCitation], answer: String?) async throws -> AskEvidence {
        evidenceRequests.append((citations, answer))
        if evidenceHangs { await withCheckedContinuation { evidenceContinuation = $0 } }
        if evidenceFails { throw EvidenceTestError.refused }
        return evidence
    }

    func resolveEvidence() {
        evidenceContinuation?.resume()
        evidenceContinuation = nil
    }

    func loadAskSourceMeetings(limit _: Int) async throws -> [AskSourceMeetingOption] {
        sourceMeetings
    }

    func suggestAskFollowUps(question: String, answer _: String, citations _: [AskCitation]) async throws -> [String] {
        let index = followUpRequests.count
        followUpRequests.append(question)
        let suggestions = await withCheckedContinuation { followUpContinuations[index] = $0 }
        if Task.isCancelled { cancelledFollowUps.append(index) }
        return suggestions
    }

    func resolveFollowUps(at index: Int, _ suggestions: [String]) {
        followUpContinuations.removeValue(forKey: index)?.resume(returning: suggestions)
    }
}
