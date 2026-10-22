import Foundation
import XCTest

@testable import ApplicationKit

final class AskDictationQuestionTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Bogota")!
        calendar.firstWeekday = 2
        return calendar
    }

    /// Thursday, October 22, 2026, 10:00 in Bogotá.
    private var now: Date { day(2026, 10, 22, hour: 10) }

    func testTodayAndYesterdayAreListingsInBothLanguages() {
        for question in ["dame los dictados de hoy", "Give me today's dictations", "¿Qué dicté hoy?"] {
            let parsed = parse(question)
            XCTAssertEqual(parsed.period, interval(day(2026, 10, 22), days: 1), question)
            XCTAssertEqual(parsed.searchWords, [], question)
            XCTAssertTrue(parsed.isListing, question)
        }
        XCTAssertEqual(parse("what did I dictate yesterday").period, interval(day(2026, 10, 21), days: 1))
        XCTAssertEqual(parse("los de anteayer").period, interval(day(2026, 10, 20), days: 1))
    }

    func testAnAppAfterAPrepositionBecomesAFilter() {
        let parsed = parse("qué dicté ayer en Slack", applications: ["Slack", "Mail"])
        let words = parse("what did I say about Slack", applications: ["Slack"])
        let longest = parse("notas en microsoft word", applications: ["Word", "Microsoft Word"])

        XCTAssertEqual(parsed.applicationName, "Slack")
        XCTAssertEqual(parsed.period, interval(day(2026, 10, 21), days: 1))
        XCTAssertEqual(parsed.searchWords, [])
        XCTAssertNil(words.applicationName, "without a preposition the app name is a topic")
        XCTAssertEqual(words.searchWords, ["slack"])
        XCTAssertEqual(longest.applicationName, "Microsoft Word")
        XCTAssertEqual(longest.searchWords, ["notas"])
        XCTAssertEqual(parse("Slack", applications: ["Slack"]).searchWords, ["slack"])
        XCTAssertNil(parse("", applications: ["Slack"]).applicationName)
    }

    func testWeeksMonthsAndPartsOfTheDay() {
        XCTAssertEqual(parse("what did I say about the budget this week").period, interval(day(2026, 10, 19), days: 7))
        XCTAssertEqual(parse("what did I say about the budget this week").searchWords, ["budget"])
        XCTAssertEqual(parse("la semana pasada").period, interval(day(2026, 10, 12), days: 7))
        XCTAssertEqual(parse("este mes").period, interval(day(2026, 10, 1), days: 31))
        XCTAssertEqual(parse("last month").period, interval(day(2026, 9, 1), days: 30))
        XCTAssertEqual(
            parse("esta mañana").period, DateInterval(start: day(2026, 10, 22), end: day(2026, 10, 22, hour: 12)))
        XCTAssertEqual(
            parse("los últimos 3 días").period, DateInterval(start: day(2026, 10, 19, hour: 10), end: now))
        XCTAssertEqual(
            parse("last two hours").period, DateInterval(start: day(2026, 10, 22, hour: 8), end: now))
    }

    func testWeekdaysAreMostRecentUnlessTheyAreTheTopic() {
        XCTAssertEqual(parse("dictados del lunes").period, interval(day(2026, 10, 19), days: 1))
        XCTAssertEqual(parse("on Thursday").period, interval(day(2026, 10, 22), days: 1))
        XCTAssertEqual(parse("last Thursday").period, interval(day(2026, 10, 15), days: 1))
        XCTAssertEqual(parse("el jueves pasado").period, interval(day(2026, 10, 15), days: 1))
        let topic = parse("lo que dije sobre el viernes")
        XCTAssertNil(topic.period)
        XCTAssertEqual(topic.searchWords, ["viernes"])
    }

    func testDaysAndWeeksAgoAndSummaries() {
        XCTAssertEqual(parse("dictado de hace dos dias").period, interval(day(2026, 10, 20), days: 1))
        XCTAssertTrue(parse("dictado de hace dos dias").isListing)
        XCTAssertEqual(parse("what I dictated 3 days ago").period, interval(day(2026, 10, 19), days: 1))
        XCTAssertEqual(parse("a week ago").period, interval(day(2026, 10, 12), days: 7))
        XCTAssertEqual(
            parse("hace 2 horas").period, DateInterval(start: day(2026, 10, 22, hour: 8), end: now))
        XCTAssertTrue(parse("resúmeme lo que dicté ayer").asksForSummary)
        XCTAssertTrue(parse("resúmeme lo que dicté ayer").isListing)
        XCTAssertFalse(parse("dame los dictados de ayer").asksForSummary)
    }

    func testDatesInferThePastYear() {
        XCTAssertEqual(parse("los del 21 de octubre").period, interval(day(2026, 10, 21), days: 1))
        XCTAssertEqual(parse("October 1st").period, interval(day(2026, 10, 1), days: 1))
        XCTAssertEqual(parse("December 3").period, interval(day(2025, 12, 3), days: 1))
        XCTAssertEqual(parse("3 de diciembre de 2024").period, interval(day(2024, 12, 3), days: 1))
        XCTAssertEqual(parse("2026-09-30").period, interval(day(2026, 9, 30), days: 1))
        XCTAssertNil(parse("31 de febrero").period)
    }

    func testContentWordsStaySearchable() {
        let parsed = parse("Send the report on Friday")
        XCTAssertEqual(parsed.period, interval(day(2026, 10, 16), days: 1))
        XCTAssertEqual(parsed.searchWords, ["send", "report"])
        XCTAssertEqual(parse("presupuesto Q3").searchWords, ["presupuesto", "q3"])
        XCTAssertFalse(parse("presupuesto").isListing)
        XCTAssertTrue(parse("dame mis dictados").isListing)
    }

    private func parse(_ question: String, applications: [String] = []) -> AskDictationQuestion {
        AskDictationQuestion.parse(question, applications: applications, now: now, calendar: calendar)
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func interval(_ start: Date, days: Int) -> DateInterval {
        DateInterval(start: start, end: calendar.date(byAdding: .day, value: days, to: start)!)
    }
}
