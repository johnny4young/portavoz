import Foundation
import XCTest

@testable import ApplicationKit
@testable import PortavozCore

final class InsightsFindingsTests: XCTestCase {
    private func fact(
        _ label: String, day: Int, minutes: Double, hasDecision: Bool,
        hasSummary: Bool = true, transcript: String = ""
    ) -> InsightsFindings.MeetingFact {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = DateComponents(calendar: cal, year: 2026, month: 7, day: day, hour: 10).date!
        return InsightsFindings.MeetingFact(
            id: MeetingID(), startedAt: start, seconds: minutes * 60,
            hasSummary: hasSummary, hasDecision: hasDecision, transcript: transcript)
    }

    func testNoDecisionFlagsIdleMeetingsAndSumsTime() throws {
        let facts = [
            fact("decided", day: 14, minutes: 30, hasDecision: true),
            fact("idle-a", day: 15, minutes: 20, hasDecision: false),
            fact("idle-b", day: 16, minutes: 40, hasDecision: false),
        ]
        let finding = try XCTUnwrap(InsightsFindings.noDecision(facts))
        XCTAssertEqual(finding.count, 2)
        XCTAssertEqual(finding.totalSeconds, 60 * 60, accuracy: 0.5)  // 20 + 40 min
        // Most recent idle meeting drives the action (day 16).
        XCTAssertEqual(finding.mostRecent, facts[2].id)
    }

    func testNoDecisionIgnoresUnsummarizedMeetings() {
        // Two decision-less meetings, but neither is summarized yet — they're
        // unjudged, not failures, so nothing is flagged.
        let facts = [
            fact("a", day: 15, minutes: 20, hasDecision: false, hasSummary: false),
            fact("b", day: 16, minutes: 40, hasDecision: false, hasSummary: false),
        ]
        XCTAssertNil(InsightsFindings.noDecision(facts))
    }

    func testNoDecisionNeedsAtLeastTwoIdleMeetings() {
        let facts = [
            fact("decided", day: 14, minutes: 30, hasDecision: true),
            fact("idle", day: 15, minutes: 20, hasDecision: false),
        ]
        XCTAssertNil(InsightsFindings.noDecision(facts))
    }

    func testRecurringTopicsCountDistinctMeetingsAndRank() {
        let facts = [
            fact("m1", day: 12, minutes: 30, hasDecision: true, transcript: "el cluster Zephyr y QVTL"),
            fact("m2", day: 13, minutes: 30, hasDecision: true, transcript: "Zephyr otra vez, y Kepler"),
            fact("m3", day: 14, minutes: 30, hasDecision: true, transcript: "cerramos Zephyr con QVTL"),
        ]
        let topics = InsightsFindings.recurringTopics(facts, minMeetings: 2, limit: 3)
        // Zephyr in 3 meetings, QVTL in 2 — Kepler (1) is filtered out.
        XCTAssertEqual(topics.map(\.term), ["Zephyr", "QVTL"])
        XCTAssertEqual(topics.first?.count, 3)
        XCTAssertFalse(topics.contains { $0.term == "Kepler" })
    }

    func testRecurringTopicCountsATermOncePerMeeting() {
        let facts = [
            fact("m1", day: 12, minutes: 30, hasDecision: true, transcript: "QVTL QVTL QVTL"),
            fact("m2", day: 13, minutes: 30, hasDecision: true, transcript: "QVTL"),
        ]
        let topics = InsightsFindings.recurringTopics(facts, minMeetings: 2)
        XCTAssertEqual(topics.first?.count, 2)  // two meetings, not four occurrences
    }

    func testTopicTermShapes() {
        XCTAssertTrue(InsightsFindings.looksLikeTopic("QVTL"))  // acronym
        XCTAssertTrue(InsightsFindings.looksLikeTopic("WhisperKit"))  // CamelCase
        XCTAssertTrue(InsightsFindings.looksLikeTopic("Qord2M"))  // letter+digit
        XCTAssertTrue(InsightsFindings.looksLikeTopic("Zephyr"))  // proper-noun shape
        XCTAssertFalse(InsightsFindings.looksLikeTopic("the"))  // lowercase
        XCTAssertFalse(InsightsFindings.looksLikeTopic("OK"))  // stoplisted acronym
        XCTAssertFalse(InsightsFindings.looksLikeTopic("It's"))  // contraction, never a topic
    }

    func testRecurringTopicsIgnoreSentenceStarters() {
        // "Thank" is only ever a sentence-opener → not a topic. "Zephyr"
        // appears mid-sentence → a real proper-noun topic.
        let facts = [
            fact("m1", day: 12, minutes: 30, hasDecision: true,
                transcript: "We shipped Zephyr today. Thank you all."),
            fact("m2", day: 13, minutes: 30, hasDecision: true,
                transcript: "The Zephyr rollout is done. Thank you."),
        ]
        let topics = InsightsFindings.recurringTopics(facts, minMeetings: 2)
        XCTAssertEqual(topics.map(\.term), ["Zephyr"])
    }

    func testRecurringTopicsExcludeParticipantNames() {
        let facts = [
            fact("m1", day: 12, minutes: 30, hasDecision: true, transcript: "hoy Marta lidera Zephyr"),
            fact("m2", day: 13, minutes: 30, hasDecision: true, transcript: "otra vez Marta con Zephyr"),
        ]
        // "Marta" is a participant, not a topic — excluded; "Zephyr" stays.
        let topics = InsightsFindings.recurringTopics(facts, exclude: ["marta"], minMeetings: 2)
        XCTAssertEqual(topics.map(\.term), ["Zephyr"])
    }
}
