@testable import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class AskFollowUpsTests: XCTestCase {
    private let citation = AskCitation(
        segmentID: UUID(), meetingID: MeetingID(), meetingTitle: "Sprint demo",
        timestamp: 3, text: "The dashboards move before Friday.")

    func testAdmitsTwoOrThreeShortNewSuggestions() async throws {
        let suggest = SuggestAskFollowUps(suggesting: FixedFollowUps(result: .success([
            "  1. “Who can give Nora access?” [2]",
            "what did we agree about the dashboards?",
            "Who can give nora access?",
            "",
            "See https://example.com",
            String(repeating: "long ", count: 20),
            "What else is due\nFriday?",
            "- Draft a status note",
            "One too many"
        ])))

        let followUps = try await suggest(
            question: "What did we agree about the dashboards?", answer: "Friday [1].", citations: [citation])

        XCTAssertEqual(followUps, ["Who can give Nora access?", "What else is due Friday?", "Draft a status note"])
    }

    func testMarkdownEmphasisIsStripped() {
        XCTAssertEqual(
            SuggestAskFollowUps.admit(["**Who owns the rollout?**", "* *What else is due?*"], question: "When?"),
            ["Who owns the rollout?", "What else is due?"])
    }

    func testFewerThanTwoOrNoModelOrAFailureIsNone() async throws {
        for result: Result<[String], Error> in [
            .success(["Only one?"]), .success([]), .failure(FollowUpTestError.refused)
        ] {
            let suggest = SuggestAskFollowUps(suggesting: FixedFollowUps(result: result))
            let followUps = try await suggest(question: "When?", answer: "Friday [1].", citations: [citation])
            XCTAssertEqual(followUps, [])
        }
    }

    func testNothingIsAskedWithoutAQuestionAnswerOrEvidence() async throws {
        let model = FixedFollowUps(result: .success(["A?", "B?"]))
        let suggest = SuggestAskFollowUps(suggesting: model)
        let noAnswer = try await suggest(question: "When?", answer: " ", citations: [citation])
        let noEvidence = try await suggest(question: "When?", answer: "Friday.", citations: [])
        let noQuestion = try await suggest(question: "\n", answer: "Friday.", citations: [citation])
        XCTAssertEqual(noAnswer + noEvidence + noQuestion, [])
        XCTAssertEqual(model.calls.value, 0)
    }

    func testOnlyThePassagesTheAnswerCitesAreSent() async throws {
        let other = AskCitation(
            segmentID: UUID(), meetingID: MeetingID(), meetingTitle: "Retro", timestamp: 9, text: "Unrelated.")
        let model = FixedFollowUps(result: .success([]))
        let suggest = SuggestAskFollowUps(suggesting: model)
        _ = try await suggest(question: "When?", answer: "Friday [2].", citations: [other, citation])
        _ = try await suggest(question: "When?", answer: "Friday.", citations: [other, citation])
        XCTAssertEqual(model.sent.value, [[citation], [other, citation]])
    }

    func testASlowModelTimesOutToNone() async throws {
        let suggest = SuggestAskFollowUps(
            suggesting: HangingFollowUps(), timeout: .milliseconds(50))
        let followUps = try await suggest(question: "When?", answer: "Friday [1].", citations: [citation])
        XCTAssertEqual(followUps, [])
    }
}

private enum FollowUpTestError: Error { case refused }

private final class FixedFollowUps: AskFollowUpSuggesting, @unchecked Sendable {
    let result: Result<[String], Error>
    let calls = LockedCount()
    let sent = LockedValue<[[AskCitation]]>([])

    init(result: Result<[String], Error>) {
        self.result = result
    }

    func followUps(question _: String, answer _: String, citations: [AskCitation]) async throws -> [String] {
        calls.increment()
        sent.mutate { $0.append(citations) }
        return try result.get()
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

private struct HangingFollowUps: AskFollowUpSuggesting {
    func followUps(question _: String, answer _: String, citations _: [AskCitation]) async throws -> [String] {
        try await Task.sleep(for: .seconds(30))
        return ["Too late?", "Way too late?"]
    }
}
