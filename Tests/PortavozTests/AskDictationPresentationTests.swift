import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

@testable import portavoz_app

@MainActor
final class AskDictationPresentationTests: XCTestCase {
    private let citation = AskDictationCitation(
        dictationID: DictationRecordID(), createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        applicationName: "Slack", delivery: .verified, text: "Send the report on Friday.")

    func testDictationsAskOnlyWhileTheHistoryIsOnAndKeepTheirOwnCitations() async throws {
        let client = DictationAskClient()
        let model = AskModel(client: client)
        model.selectSourceMode(.dictations)
        model.refreshDictationSource()
        try await waitUntil { model.state.dictationSourceState == .historyOff }
        model.updateDraft("report")
        model.submit()
        XCTAssertFalse(model.state.isAsking, "Nothing is asked while the history is off")

        client.historyIsOn = true
        model.refreshDictationSource()
        try await waitUntil { model.state.dictationSourceState == .available }
        model.updateDraft("When is the report due?")
        model.submit()
        try await waitUntil { client.questions == ["When is the report due?"] }
        XCTAssertEqual(model.state.pendingSource, .dictations)
        await client.publish([citation])
        try await waitUntil { model.state.pendingPhase == .generatingAnswer }
        XCTAssertEqual(model.state.pendingDictationCitations, [citation])

        client.complete(AskDictationAnswer(
            question: "When is the report due?", generatedText: "On Friday.",
            citations: [citation], generationOutcome: .generated))
        try await waitUntil { model.state.exchanges.count == 1 }
        let exchange = try XCTUnwrap(model.state.exchanges.first)
        XCTAssertEqual(exchange.source, .dictations)
        XCTAssertEqual(exchange.dictationCitations, [citation])
        XCTAssertTrue(exchange.citations.isEmpty && exchange.noteCitations.isEmpty)
        XCTAssertTrue(exchange.hasCitations)
        XCTAssertEqual(exchange.answer, "On Friday.")
        XCTAssertTrue(model.state.pendingDictationCitations.isEmpty)
    }

    func testHistoryTurnedOffMidAskSaysSoAndLocksTheSource() async throws {
        let client = DictationAskClient()
        client.historyIsOn = true
        let model = AskModel(client: client)
        model.selectSourceMode(.dictations)
        model.refreshDictationSource()
        try await waitUntil { model.state.dictationSourceState == .available }
        model.updateDraft("report")
        model.submit()
        try await waitUntil { client.questions == ["report"] }

        client.complete(AskDictationAnswer(
            question: "report", generatedText: nil, citations: [],
            generationOutcome: .notRequested, historyIsOff: true))
        try await waitUntil { model.state.exchanges.count == 1 }

        XCTAssertEqual(model.state.dictationSourceState, .historyOff)
        XCTAssertEqual(
            model.state.exchanges.first?.answer,
            AskAnswerPresentation.text(for: AskDictationAnswer(
                question: "", generatedText: nil, citations: [], generationOutcome: .notRequested,
                historyIsOff: true)))
    }

    func testListingsNameTheirPeriodAndAppInsteadOfAGenericAnswer() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = try XCTUnwrap(calendar.dateInterval(of: .day, for: now))
        let yesterday = try XCTUnwrap(calendar.dateInterval(of: .day, for: now.addingTimeInterval(-86_400)))
        let week = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: now))
        func text(_ scope: AskDictationScope, citations: [AskDictationCitation]) -> String {
            AskAnswerPresentation.text(
                for: AskDictationAnswer(
                    question: "q", generatedText: nil, citations: citations, generationOutcome: .notRequested,
                    listing: scope),
                now: now, calendar: calendar)
        }

        XCTAssertEqual(
            text(.init(period: today, applicationName: nil, summarize: false), citations: [citation]),
            "Your dictations from today:")
        XCTAssertEqual(
            text(.init(period: yesterday, applicationName: "Slack", summarize: false), citations: []),
            "You have no saved dictations in Slack from yesterday.")
        XCTAssertEqual(
            text(.init(period: nil, applicationName: nil, summarize: false), citations: [citation]),
            "Your most recent dictations:")
        XCTAssertTrue(
            text(.init(period: week, applicationName: nil, summarize: false), citations: [citation])
                .hasPrefix("Your dictations between "))
        XCTAssertEqual(
            AskAnswerPresentation.text(for: AskDictationAnswer(
                question: "q", generatedText: nil, citations: [], generationOutcome: .insufficientEvidence)),
            "No saved dictation mentions that.")
        XCTAssertNil(AskAnswerPresentation.statusText(for: .notRequested, hasCitations: true))
    }

    func testAnOpenedCitationShowsOnlyThatDictationUntilFiltersChange() async throws {
        let store = try MeetingStore.inMemory()
        let model = DictationHistoryModel(store: store)
        await model.load()
        await model.update(isEnabled: true)
        let write = try XCTUnwrap(model.admit())
        let wanted = record("Send the report on Friday.")
        _ = await write(wanted)
        _ = await write(record("No borres estas notas."))

        model.focus(on: wanted.id)
        await model.load()
        XCTAssertEqual(model.records.map(\.id), [wanted.id])
        XCTAssertEqual(model.filter.recordID, wanted.id)

        await model.apply(.all)
        XCTAssertEqual(model.records.count, 2)
    }

    private func record(_ text: String) -> DictationRecord {
        DictationRecord(
            id: DictationRecordID(), createdAt: Date(), duration: 1, text: text, originalText: nil,
            mode: .literal, language: nil, engine: "parakeet", applicationName: "Slack",
            applicationBundleID: nil, delivery: .verified)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw DictationAskTestError.timeout }
            await Task.yield()
        }
    }
}

private enum DictationAskTestError: Error {
    case timeout
    case unused
}

@MainActor
private final class DictationAskClient: AskModelClient {
    var historyIsOn = false
    private(set) var questions: [String] = []
    private var receiver: AskDictationEvidenceReceiver?
    private var continuation: CheckedContinuation<AskDictationAnswer, Error>?

    func searchAskMeetings(_: String, source _: AskSourceScope, limit _: Int) async throws -> [AskSearchResult] {
        throw DictationAskTestError.unused
    }

    func answerAskMeetings(_: String, source _: AskSourceScope, limit _: Int) async throws -> AskMeetingAnswer {
        throw DictationAskTestError.unused
    }

    func askDictationHistoryIsOn() async throws -> Bool {
        historyIsOn
    }

    func answerAskDictations(
        _ question: String,
        limit _: Int,
        onEvidence: @escaping AskDictationEvidenceReceiver
    ) async throws -> AskDictationAnswer {
        questions.append(question)
        receiver = onEvidence
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func publish(_ citations: [AskDictationCitation]) async {
        await receiver?(citations)
    }

    func complete(_ answer: AskDictationAnswer) {
        receiver = nil
        continuation?.resume(returning: answer)
        continuation = nil
    }
}
