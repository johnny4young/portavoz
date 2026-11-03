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
            parse("los últimos 3 días").period, DateInterval(start: day(2026, 10, 19), end: now))
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
        XCTAssertEqual(parse("dictado de hace dos dias").period, DateInterval(start: day(2026, 10, 20), end: now))
        XCTAssertTrue(parse("dictado de hace dos dias").isListing)
        XCTAssertEqual(parse("what I dictated 3 days ago").period, DateInterval(start: day(2026, 10, 19), end: now))
        XCTAssertEqual(parse("a week ago").period, DateInterval(start: day(2026, 10, 15), end: now))
        XCTAssertEqual(parse("notas de hace una semana").period, DateInterval(start: day(2026, 10, 15), end: now))
        XCTAssertEqual(parse("la semana pasada").period, interval(day(2026, 10, 12), days: 7))
        XCTAssertEqual(
            parse("hace 2 horas").period, DateInterval(start: day(2026, 10, 22, hour: 8), end: now))
        XCTAssertTrue(parse("resúmeme lo que dicté ayer").asksForSummary)
        XCTAssertTrue(parse("resúmeme lo que dicté ayer").isListing)
        XCTAssertFalse(parse("dame los dictados de ayer").asksForSummary)
    }

    /// A named unit covers that whole unit; a span counted back reaches until now.
    func testBilingualPeriodVariants() {
        let since = { (start: Date) in DateInterval(start: start, end: self.now) }
        let cases: [(DateInterval, [String])] = [
            (interval(day(2026, 10, 12), days: 7), [
                "la semana pasada", "semana anterior", "last week", "the previous week"]),
            (since(day(2026, 10, 15)), [
                "hace una semana", "hace 1 semana", "a week ago", "one week ago", "la última semana",
                "en la última semana", "durante la última semana", "the past week", "in the last week",
                "over the past week", "desde hace una semana", "since a week ago", "recientemente",
                "últimamente", "hace poco", "recently", "lately"]),
            (since(day(2026, 10, 20)), ["hace un par de días", "a couple of days ago", "a couple days ago",
                                        "hace dos días", "2 days ago", "desde el 20 de octubre", "since October 20"]),
            (since(day(2026, 10, 19)), [
                "hace unos días", "hace algunos días", "hace días", "a few days ago", "los últimos días",
                "the last few days", "the past few days", "over the last few days", "desde el lunes",
                "since Monday"]),
            (since(day(2026, 10, 8)), ["las últimas dos semanas", "the past 2 weeks", "last 2 weeks",
                                       "hace dos semanas", "two weeks ago"]),
            (since(day(2026, 9, 22)), ["hace un mes", "a month ago", "el último mes", "the past month"]),
            (since(day(2026, 10, 21)), ["desde ayer", "since yesterday"]),
            (DateInterval(start: day(2026, 10, 22, hour: 7), end: now), [
                "hace 3 horas", "3 hours ago", "the last 3 hours", "las últimas tres horas"]),
            (interval(day(2026, 9, 1), days: 30), ["el mes pasado", "el mes anterior", "last month", "previous month"]),
            (interval(day(2026, 1, 1), days: 365), ["este año", "this year"]),
            (interval(day(2025, 1, 1), days: 365), ["el año pasado", "last year"]),
            (DateInterval(start: day(2026, 10, 21, hour: 18), end: day(2026, 10, 22, hour: 6)), [
                "anoche", "ayer por la noche", "ayer en la noche", "last night"]),
            (DateInterval(start: day(2026, 10, 22, hour: 18), end: day(2026, 10, 23)), [
                "esta noche", "tonight", "this evening"]),
            (interval(day(2026, 10, 17), days: 2), [
                "el fin de semana", "este fin de semana", "this weekend", "the weekend",
                "el fin de semana pasado", "last weekend"])
        ]
        for (expected, phrases) in cases {
            for phrase in phrases {
                XCTAssertEqual(parse("dictados de " + phrase).period, expected, phrase)
                XCTAssertTrue(parse("dictados de " + phrase).isListing, phrase)
            }
        }
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
