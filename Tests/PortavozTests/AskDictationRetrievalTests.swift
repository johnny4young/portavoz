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
        let evidence = try await LocalAskDictationRetrieval(store: store).retrieve(question: "report", limit: 6)

        XCTAssertNil(rows)
        XCTAssertEqual(evidence, .historyOff)
    }

    func testAnyWordMatchesAndTheBestMatchComesFirst() async throws {
        let store = try await populatedStore()

        let evidence = try await LocalAskDictationRetrieval(store: store).retrieve(
            question: "When do I send the report?", limit: 6)
        let noWord = try await store.dictationRecordsForAsk(matchingAny: ["¿?", "🙂"], limit: 10)

        guard case .found(let citations) = evidence else { return XCTFail("expected evidence") }
        XCTAssertEqual(citations.first?.text, "Send the report on Friday.")
        XCTAssertEqual(citations.first?.applicationName, "Slack")
        XCTAssertTrue(citations.contains { $0.text == "Report the crash to the team." })
        XCTAssertFalse(citations.contains { $0.text == "No borres estas notas." })
        XCTAssertEqual(noWord, [])
    }

    func testQuestionSyntaxIsMatchedAsTextNeverRun() async throws {
        let store = try await populatedStore()
        for question in ["\"", "NEAR(report friday)", "text:report", "report*", "'; DROP TABLE dictationRecord;--"] {
            _ = try await store.dictationRecordsForAsk(matchingAny: [question], limit: 10)
        }
        let columnSyntax = try await store.dictationRecordsForAsk(matchingAny: ["originalText:eh"], limit: 10)
        let stillThere = try await store.dictationRecords(limit: 10).count

        XCTAssertEqual(columnSyntax, [])
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
                DictationRecord(
                    id: DictationRecordID(), createdAt: now.addingTimeInterval(Double(-offset)), duration: 2,
                    text: sample.0, originalText: sample.1, mode: .literal, language: "en", engine: "parakeet",
                    applicationName: sample.2, applicationBundleID: nil, delivery: .verified),
                admittedGeneration: 0, at: now)
        }
        return store
    }

    private func record(_ text: String) -> DictationRecord {
        DictationRecord(
            id: DictationRecordID(), createdAt: now, duration: 1, text: text, originalText: nil,
            mode: .literal, language: nil, engine: "parakeet", applicationName: nil,
            applicationBundleID: nil, delivery: .verified)
    }
}
