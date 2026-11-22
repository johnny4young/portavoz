import ApplicationKit
import Foundation
import PortavozCore
import SwiftUI
import XCTest

@testable import portavoz_app

final class HomeNextMeetingHeroTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let posix = Locale(identifier: "en_US_POSIX")

    func testCountsMinutesAndSecondsUnderAnHour() {
        XCTAssertEqual(
            NextMeetingCountdown(start: start, at: start.addingTimeInterval(-(44 * 60 + 38)), locale: posix),
            .counting(lead: "44", trail: ":38", unit: .minutes))
        XCTAssertEqual(
            NextMeetingCountdown(start: start, at: start.addingTimeInterval(-0.2), locale: posix),
            .counting(lead: "00", trail: ":01", unit: .minutes),
            "a partial second still counts until the start")
    }

    func testCountsWholeMinutesPastAnHour() {
        XCTAssertEqual(
            NextMeetingCountdown(start: start, at: start.addingTimeInterval(-3_600), locale: posix),
            .counting(lead: "60", trail: ":00", unit: .minutes))
        XCTAssertEqual(
            NextMeetingCountdown(start: start, at: start.addingTimeInterval(-3_600.5), locale: posix),
            .counting(lead: "1", trail: ":00", unit: .hours))
        XCTAssertEqual(
            NextMeetingCountdown(start: start, at: start.addingTimeInterval(-3_720), locale: posix),
            .counting(lead: "1", trail: ":01", unit: .hours),
            "a tick on the minute shows the minute that follows it")
        XCTAssertEqual(
            NextMeetingCountdown(
                start: start, at: start.addingTimeInterval(-(2 * 3_600 + 15 * 60 + 59)), locale: posix),
            .counting(lead: "2", trail: ":15", unit: .hours))
    }

    func testScheduleTicksPerMinuteThenPerSecondAndStopsAtTheStart() {
        var entries = CountdownSchedule(start: start)
            .entries(from: start.addingTimeInterval(-3_725.5), mode: .normal)
        let offsets = (0..<4).compactMap { _ in entries.next() }
            .map { start.timeIntervalSince($0) }
        XCTAssertEqual(offsets, [3_725.5, 3_720, 3_660, 3_600])
        XCTAssertEqual(entries.next().map { start.timeIntervalSince($0) }, 3_599)

        var last = CountdownSchedule(start: start)
            .entries(from: start.addingTimeInterval(-1.5), mode: .normal)
        XCTAssertEqual(
            [last.next(), last.next(), last.next()].compactMap { $0 }.map { start.timeIntervalSince($0) },
            [1.5, 1, 0])
        XCTAssertNil(last.next(), "nothing ticks once the meeting has started")
    }

    func testSwitchesToNowAtTheStart() {
        XCTAssertEqual(NextMeetingCountdown(start: start, at: start), .now)
        XCTAssertEqual(NextMeetingCountdown(start: start, at: start.addingTimeInterval(600)), .now)
    }

    func testFactsKeepOnlyWhatTheCalendarGave() {
        let full = UpcomingEvent(
            id: "e", title: "Sync", startDate: start, attendees: [],
            endDate: start.addingTimeInterval(45 * 60), platform: .googleMeet, recurrence: .weekly)
        XCTAssertEqual(
            HomeNextMeetingHero.facts(full),
            ["Google Meet", L10n.format("%d min", 45), L10n.text("weekly")].joined(separator: " · "))

        let bare = UpcomingEvent(id: "e", title: "Sync", startDate: start, attendees: [])
        XCTAssertNil(HomeNextMeetingHero.facts(bare))
    }
}

@MainActor
final class HomeHeroLayoutTests: XCTestCase {
    private let block: CGFloat = 40
    private static let fontFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Fonts/Fraunces")

    func testTheFullCountdownNeedsTheWideSection() async {
        XCTAssertEqual(HomeHeroLayout.arrangement(width: 940), .wide)
        XCTAssertEqual(HomeHeroLayout.arrangement(width: 939), .compact)
        XCTAssertEqual(HomeHeroLayout.columns(width: 940)?.hero, 536)
        XCTAssertEqual(HomeHeroLayout.columns(width: 940)?.side, 360)
        XCTAssertEqual(HomeHeroLayout.columns(width: 1_208)?.side, 552, "the board's width gives the side its full 552 pt")
        XCTAssertEqual(height(width: 940, side: block), block, "beside the hero the section is one row tall")
    }

    func testTheCompactCountdownKeepsTheSideBesideItAtTheStandardWindow() async {
        // A 1,000 pt window leaves about 644 pt for the section.
        XCTAssertEqual(HomeHeroLayout.arrangement(width: 640), .compact)
        let at700 = HomeHeroLayout.columns(width: 700)
        XCTAssertEqual(at700?.hero, 324)
        XCTAssertEqual(at700?.side, 344)
        let at760 = HomeHeroLayout.columns(width: 760)
        XCTAssertEqual(at760?.side, 360, "the compact side stops at the wide side's minimum")
        XCTAssertEqual(at760?.hero, 368)
        XCTAssertEqual(height(width: 700, side: block), block)
        XCTAssertEqual(height(width: 760, side: block), block)
    }

    func testTheMinimumWindowStacks() async {
        // The 900 pt minimum window leaves about 544 pt.
        XCTAssertEqual(HomeHeroLayout.arrangement(width: 639), .stacked)
        XCTAssertNil(HomeHeroLayout.columns(width: 544))
        XCTAssertGreaterThan(height(width: 544, side: block), 2 * block, "stacked, the side follows after a gap")
    }

    func testAnEmptySideAddsNothingUnderAStackedHero() async {
        XCTAssertEqual(height(width: 544, side: 0), block)
    }

    func testEachCountdownFitsTheNarrowestHeroThatCarriesIt() async throws {
        XCTAssertTrue(PVFont.register(folder: Self.fontFolder))
        // Equal digit cells: the widest reading is as wide as any other.
        let start = Date().addingTimeInterval(59 * 60 + 59)
        let compact = NSHostingView(rootView: HomeCountdown(start: start, compact: true)).fittingSize.width
        let full = NSHostingView(rootView: HomeCountdown(start: start)).fittingSize.width
        XCTAssertLessThan(compact, full)
        XCTAssertLessThanOrEqual(compact, try XCTUnwrap(HomeHeroLayout.columns(width: 640)?.hero))
        XCTAssertLessThanOrEqual(full, try XCTUnwrap(HomeHeroLayout.columns(width: 940)?.hero))
    }

    private func height(width: CGFloat, side: CGFloat) -> CGFloat {
        let layout = HomeHeroLayout {
            Color.clear.frame(height: block)
            Color.clear.frame(height: side)
        }
        return NSHostingView(rootView: layout.frame(width: width)).fittingSize.height
    }
}

@MainActor
final class HomeBriefRowLayoutTests: XCTestCase {
    func testTheNameMovesAboveTheLineWhenTheLineWouldGetTooNarrow() async {
        let layout = HomeBriefRowLayout(nameWidth: 84)
        XCTAssertTrue(layout.isBeside(width: 316), "the wide side's narrowest card keeps the name column")
        XCTAssertFalse(layout.isBeside(width: 240), "the compact side's narrowest card stacks it")
        XCTAssertEqual(height(layout, width: 316), 20)
        XCTAssertEqual(height(layout, width: 240), 44)
    }

    private func height(_ layout: HomeBriefRowLayout, width: CGFloat) -> CGFloat {
        let row = layout {
            Color.clear.frame(height: 20)
            Color.clear.frame(height: 20)
        }
        return NSHostingView(rootView: row.frame(width: width)).fittingSize.height
    }
}
