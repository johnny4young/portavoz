import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class BriefRelevanceTests: XCTestCase {
    private func passage(_ meeting: MeetingID, _ title: String, _ text: String) -> AskCitation {
        AskCitation(meetingID: meeting, meetingTitle: title, timestamp: 0, text: text)
    }

    func testTermsDeduplicateAndDropShortWords() {
        let terms = BriefRelevance.terms(
            eventTitle: "Platform Team Sprint Demo",
            attendees: ["Daniel Pérez", "Team International"])
        XCTAssertTrue(terms.contains("Platform"))
        XCTAssertTrue(terms.contains("Daniel"))
        XCTAssertFalse(terms.contains { $0.count < 3 })
        XCTAssertEqual(terms.filter { $0.lowercased() == "team" }.count, 1, "deduplicated")
    }

    func testWeakSinglePassageWithoutTermsIsDropped() {
        // The field bug: an unrelated 1:1 ("blood tests") surfaced with one
        // spurious passage and zero event terms — score 1 < 3 → gone.
        let unrelated = MeetingID()
        let ranked = BriefRelevance.rank(
            passages: [passage(unrelated, "1:1 salud", "resultados de los exámenes de sangre")],
            terms: ["Platform", "Sprint", "Daniel"])
        XCTAssertTrue(ranked.isEmpty)
    }

    func testTermMatchesKeepAndExplainTheMeeting() {
        let sprint = MeetingID()
        let ranked = BriefRelevance.rank(
            passages: [
                passage(sprint, "Sprint review", "el equipo de plataforma cerró el sprint demo")
            ],
            terms: ["Platform", "Sprint", "Demo"])
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked[0].meetingID, sprint)
        XCTAssertEqual(ranked[0].matchedTerms, ["Sprint", "Demo"], "the visible reason")
    }

    func testMatchingIsCaseAndDiacriticInsensitive() {
        let meeting = MeetingID()
        let ranked = BriefRelevance.rank(
            passages: [passage(meeting, "Sync", "hablamos con DANIEL PEREZ del sprint")],
            terms: ["Daniel", "Pérez"])
        XCTAssertEqual(ranked.first?.matchedTerms, ["Daniel", "Pérez"])
    }

    func testStrongSemanticOnlyMatchSurvivesViaPassageCount() {
        let meeting = MeetingID()
        let passages = (0..<3).map { index in
            passage(meeting, "Arquitectura", "pasaje semántico \(index) sin términos del evento")
        }
        let ranked = BriefRelevance.rank(passages: passages, terms: ["Platform"])
        XCTAssertEqual(ranked.count, 1, "3 fused passages = real relatedness")
        XCTAssertTrue(ranked[0].matchedTerms.isEmpty)
        XCTAssertFalse(ranked[0].snippet.isEmpty, "snippet becomes the reason")
    }

    func testOrderingByScoreAndLimit() {
        let strong = MeetingID()
        let weak = MeetingID()
        let passages = [
            passage(strong, "Strong", "sprint demo platform daniel"),
            passage(strong, "Strong", "more sprint talk"),
            passage(weak, "Weak", "menciona sprint una vez"),
        ]
        let ranked = BriefRelevance.rank(
            passages: passages, terms: ["Sprint", "Platform", "Daniel"], limit: 1)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked[0].title, "Strong")
    }
}

final class TitleTemplateEventTests: XCTestCase {
    func testEventTitleIsDatePrefixedSoWeekliesDoNotCollide() {
        let date = Date(timeIntervalSince1970: 1_783_500_000)  // 2026-07-08 UTC
        let title = TitleTemplate.eventTitle("Platform Team Sprint Demo", date: date)
        XCTAssertTrue(title.hasSuffix(" Platform Team Sprint Demo"))
        let prefix = title.prefix(10)
        XCTAssertEqual(prefix.filter { $0 == "-" }.count, 2, "yyyy-MM-dd prefix")
        XCTAssertTrue(prefix.hasPrefix("2026-07-"))
    }
}
