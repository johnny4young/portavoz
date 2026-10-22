import Foundation
import PortavozCore
import XCTest

@testable import ApplicationKit
@testable import StorageKit

final class AskDictationRetrievalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNothingIsReadWhileTheHistoryIsOff() async throws {
        let store = try await populatedStore()
        _ = try await store.setDictationHistoryPolicy(isEnabled: false, keepsOriginal: false, retentionDays: 30, at: now)

        let rows = try await store.dictationRecordsForAsk(matchingAny: ["report"], limit: 10)
        let applications = try await store.dictationApplicationsForAsk()
        let evidence = try await retrieval(store).retrieve(question: "dame los dictados de hoy", limit: 6)

        XCTAssertNil(rows)
        XCTAssertNil(applications)
        XCTAssertEqual(evidence, .historyOff)
    }

    func testAnyWordMatchesAndTheBestMatchComesFirst() async throws {
        let store = try await populatedStore()

        let evidence = try await retrieval(store).retrieve(question: "When do I send the report?", limit: 6)

        guard case .found(let citations) = evidence else { return XCTFail("expected evidence") }
        XCTAssertEqual(citations.first?.text, "Send the report on Friday.")
        XCTAssertEqual(citations.first?.applicationName, "Slack")
        XCTAssertTrue(citations.contains { $0.text == "Report the crash to the team." })
        XCTAssertFalse(citations.contains { $0.text == "No borres estas notas." })
    }

    func testAPeriodWithNothingToSearchListsItsNewestDictations() async throws {
        let store = try await populatedStore()
        _ = try await store.recordDictation(
            record("Dictated last week.", app: "Slack", createdAt: now.addingTimeInterval(-8 * 86_400)),
            admittedGeneration: 0, at: now)

        let today = try await retrieval(store).retrieve(question: "dame los dictados de hoy", limit: 12)
        let slack = try await retrieval(store).retrieve(question: "what did I dictate in Slack", limit: 12)
        let everything = try await retrieval(store).retrieve(question: "dame mis dictados", limit: 12)

        guard case .listed(let todays, let scope) = today else { return XCTFail("expected a listing") }
        XCTAssertEqual(todays.map(\.text), [
            "No borres estas notas.", "Send the report on Friday.",
            "Report the crash to the team.", "Revisa la acción pendiente."
        ])
        XCTAssertNotNil(scope.period)
        XCTAssertFalse(scope.summarize)
        guard case .listed(let slackCitations, _) = slack else { return XCTFail("expected a listing") }
        XCTAssertEqual(slackCitations.map(\.text), ["Send the report on Friday.", "Dictated last week."])
        guard case .listed(let all, _) = everything else { return XCTFail("expected a listing") }
        XCTAssertEqual(all.count, 5)
    }

    func testWordsSearchWithinTheFiltersThenEverywhereThenListTheFilters() async throws {
        let store = try await populatedStore()

        let inPeriod = try await retrieval(store).retrieve(question: "the report today", limit: 6)
        let topicWeekday = try await retrieval(store).retrieve(question: "acción on Monday", limit: 6)
        let nothingMatches = try await retrieval(store).retrieve(question: "presupuesto de hoy", limit: 6)

        guard case .found(let found) = inPeriod else { return XCTFail("expected matches") }
        XCTAssertEqual(found.first?.text, "Send the report on Friday.")
        guard case .found(let topic) = topicWeekday else { return XCTFail("expected matches outside Monday") }
        XCTAssertEqual(topic.map(\.text), ["Revisa la acción pendiente."])
        guard case .listed(let listed, _) = nothingMatches else { return XCTFail("expected today's listing") }
        XCTAssertEqual(listed.count, 4)
        let emptyDay = try await retrieval(store).retrieve(question: "dictados de anteayer", limit: 6)
        guard case .listed(let none, let scope) = emptyDay else { return XCTFail("expected an empty listing") }
        XCTAssertEqual(none, [])
        XCTAssertNotNil(scope.period, "an empty listing still names its period")
    }

    func testOnDeviceRewritesFindDictationsInTheOtherLanguage() async throws {
        let store = try await populatedStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = now
        func retrieval(_ rewriter: any AskQueryExpanding) -> LocalAskDictationRetrieval {
            LocalAskDictationRetrieval(store: store, rewriter: rewriter, now: { now }, calendar: calendar)
        }

        let plain = try await retrieval(FixedRewriter([])).retrieve(question: "¿Qué informe envío?", limit: 6)
        let rewritten = try await retrieval(FixedRewriter(["send report", "enviar informe"]))
            .retrieve(question: "¿Qué informe envío?", limit: 6)
        let failing = try await retrieval(FailingRewriter()).retrieve(question: "the report", limit: 6)

        XCTAssertEqual(plain, .found([]))
        guard case .found(let citations) = rewritten else { return XCTFail("expected rewritten matches") }
        XCTAssertEqual(citations.first?.text, "Send the report on Friday.")
        guard case .found(let fallback) = failing else { return XCTFail("a failed rewrite keeps the word search") }
        XCTAssertEqual(fallback.first?.text, "Send the report on Friday.")
    }

    func testQuestionSyntaxIsMatchedAsTextNeverRun() async throws {
        let store = try await populatedStore()
        for question in ["\"", "NEAR(report friday)", "text:report", "report*", "'; DROP TABLE dictationRecord;--"] {
            _ = try await store.dictationRecordsForAsk(matchingAny: [question], limit: 10)
        }
        let columnSyntax = try await store.dictationRecordsForAsk(matchingAny: ["originalText:eh"], limit: 10)
        let noWord = try await store.dictationRecordsForAsk(matchingAny: ["¿?", "🙂"], limit: 10)
        let stillThere = try await store.dictationRecords(limit: 10).count

        XCTAssertEqual(columnSyntax, [])
        XCTAssertEqual(noWord?.count, 4, "no usable word lists the newest")
        XCTAssertEqual(stillThere, 4)
    }

    func testTheQueryKeepsUniqueBoundedQuotedWords() {
        XCTAssertNil(MeetingStore.dictationAskQuery(["  ¿? -- "]))
        XCTAssertEqual(
            MeetingStore.dictationAskQuery(["Send \"rep", "send report"]),
            "\"send\" OR \"\"\"rep\" OR \"report\"")
        let many = (1...80).map { "w\($0)" }.joined(separator: " ")
        let words = MeetingStore.dictationAskQuery([many])?.components(separatedBy: " OR ")
        XCTAssertEqual(words?.count, MeetingStore.maximumDictationAskTerms)
    }

    func testSelectionCitesWholeDictationsWithinTheBudget() {
        let long = String(repeating: "a", count: AskDictationLimits.maximumCitationCharacters + 1)
        let half = String(repeating: "b", count: AskDictationLimits.maximumAggregateCharacters / 2)
        let records = [record(long), record("  Short one.  "), record(half), record(half), record("Last.")]

        let citations = LocalAskDictationRetrieval.select(records, limit: 6)

        XCTAssertEqual(citations.map(\.text), ["Short one.", half, "Last."])
        XCTAssertEqual(LocalAskDictationRetrieval.select(records, limit: 1).map(\.text), ["Short one."])
    }

    func testTheFocusFilterShowsOnlyThatDictation() async throws {
        let store = try await populatedStore()
        let matches = try await store.dictationRecords(matching: .init(query: "friday"), limit: 10)
        let report = try XCTUnwrap(matches.first)

        let focused = try await store.dictationRecords(matching: .init(recordID: report.id), limit: 10)
        let missing = try await store.dictationRecords(matching: .init(recordID: DictationRecordID()), limit: 10)

        XCTAssertEqual(focused.map(\.id), [report.id])
        XCTAssertEqual(missing, [])
        XCTAssertFalse(DictationRecordFilter(recordID: report.id).isUnfiltered)
    }

    private func populatedStore() async throws -> MeetingStore {
        let store = try MeetingStore.inMemory()
        _ = try await store.setDictationHistoryPolicy(isEnabled: true, keepsOriginal: true, retentionDays: 30, at: now)
        let samples: [(String, String?, String)] = [
            ("No borres estas notas.", "eh no borres estas notas", "Notes"),
            ("Send the report on Friday.", nil, "Slack"),
            ("Report the crash to the team.", nil, "Mail"),
            ("Revisa la acción pendiente.", nil, "Mail")
        ]
        for (offset, sample) in samples.enumerated() {
            _ = try await store.recordDictation(
                record(sample.0, original: sample.1, app: sample.2, createdAt: now.addingTimeInterval(Double(-offset * 60))),
                admittedGeneration: 0, at: now)
        }
        return store
    }

    /// `now` is Friday, January 15, 2027, 08:00 UTC; the calendar is UTC.
    private func retrieval(_ store: MeetingStore) -> LocalAskDictationRetrieval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = now
        return LocalAskDictationRetrieval(store: store, rewriter: FixedRewriter([]), now: { now }, calendar: calendar)
    }

    private func record(
        _ text: String, original: String? = nil, app: String? = nil, createdAt: Date? = nil
    ) -> DictationRecord {
        DictationRecord(
            id: DictationRecordID(), createdAt: createdAt ?? now, duration: 1, text: text, originalText: original,
            mode: .literal, language: nil, engine: "parakeet", applicationName: app,
            applicationBundleID: nil, delivery: .verified)
    }
}

/// Returns the question followed by fixed rewrites, as the on-device expansion does.
private struct FixedRewriter: AskQueryExpanding {
    let rewrites: [String]

    init(_ rewrites: [String]) {
        self.rewrites = rewrites
    }

    func expand(_ question: String) async throws -> [String] { [question] + rewrites }
}

private struct FailingRewriter: AskQueryExpanding {
    func expand(_ question: String) async throws -> [String] { throw CocoaError(.featureUnsupported) }
}
