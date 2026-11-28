import ApplicationKit
import Foundation
import XCTest

@testable import portavoz_app

final class RecordingLiveStripLayoutTests: XCTestCase {
    private typealias Layout = RecordingLiveStripLayout

    func testTheHorizonIsElapsedRoundedUpToTheNextMajorMark() {
        XCTAssertEqual(Layout.scale(elapsed: 12 * 60 + 4, width: 916).horizon, 900)
        XCTAssertEqual(Layout.scale(elapsed: 900, width: 916).horizon, 900, "an exact mark is its own horizon")
        XCTAssertEqual(Layout.scale(elapsed: 901, width: 916).horizon, 1_200)
        XCTAssertEqual(Layout.scale(elapsed: 0, width: 916).horizon, 300, "the clock starts with the first major ahead")
        XCTAssertEqual(Layout.scale(elapsed: -5, width: 916).horizon, 300)
        XCTAssertEqual(Layout.scale(elapsed: .nan, width: 916).horizon, 300)
    }

    func testMajorsStepUpWhenTheyWouldCrowd() {
        XCTAssertEqual(Layout.scale(elapsed: 12 * 60 + 4, width: 916), .init(horizon: 900, major: 300))
        // 70 min at 5 min majors is 15 gaps of 61 pt; 10 min majors give 130 pt.
        XCTAssertEqual(Layout.scale(elapsed: 70 * 60, width: 916), .init(horizon: 4_200, major: 600))
        XCTAssertEqual(Layout.scale(elapsed: 70 * 60, width: 300), .init(horizon: 5_400, major: 1_800))
        XCTAssertEqual(Layout.scale(elapsed: 3 * 3_600 + 1, width: 916), .init(horizon: 11_700, major: 900))
        XCTAssertEqual(
            Layout.scale(elapsed: 9 * 3_600, width: 200), .init(horizon: 16 * 3_600, major: 8 * 3_600),
            "past the hour step, majors keep doubling")
        XCTAssertEqual(
            Layout.scale(elapsed: 40 * 60, width: 0), .init(horizon: 3_600, major: 3_600),
            "an unmeasured width settles on one major instead of looping")

        for (elapsed, width) in [(100.0, 916.0), (4_000, 916), (4_000, 320), (30_000, 500)] {
            let scale = Layout.scale(elapsed: elapsed, width: width)
            XCTAssertGreaterThanOrEqual(scale.horizon, elapsed)
            XCTAssertEqual(scale.horizon.truncatingRemainder(dividingBy: scale.major), 0)
            XCTAssertGreaterThanOrEqual(width * scale.major / scale.horizon, Layout.minimumMajorSpacing)
        }
    }

    func testTheRulerHasAMinorEveryFifthOfAMajor() {
        let marks = Layout.scale(elapsed: 12 * 60 + 4, width: 916).marks
        XCTAssertEqual(marks.count, 16)
        XCTAssertEqual(marks.filter(\.isMajor).map(\.time), [0, 300, 600, 900])
        XCTAssertEqual(marks[1], .init(time: 60, isMajor: false))

        let long = Layout.scale(elapsed: 70 * 60, width: 300)
        XCTAssertEqual(long.minor, 360)
        XCTAssertEqual(long.marks.filter(\.isMajor).map(\.time), [0, 1_800, 3_600, 5_400])
    }

    /// Past the hour the ruler and the tick labels keep counting minutes.
    func testTimesPastOneHourReadAsMinutes() {
        XCTAssertEqual(ClockFormat.mmss(3_900), "65:00")
        XCTAssertEqual(
            RecordingLiveStripLabel.text(.init(id: UUID(), kind: .note, time: 3_725)), "your note · 62:05")
    }

    func testAQuestionNamesItsAskerOnlyWhenLabelled() {
        func text(_ key: String?) -> String {
            RecordingLiveStripLabel.text(.init(id: UUID(), kind: .askedYou(by: key), time: 680))
        }
        XCTAssertEqual(text("S2"), "S2 asked you · 11:20")
        XCTAssertEqual(text(nil), "Asked you · 11:20")
        XCTAssertEqual(text(LiveVoiceStage.unlabelledKey), "Asked you · 11:20")
        XCTAssertEqual(text(LiveVoiceStage.youKey), "Asked you · 11:20")
    }

    func testTimeMapsOntoTheWidthAndClamps() {
        let scale = Layout.Scale(horizon: 900, major: 300)
        XCTAssertEqual(scale.x(450, width: 900), 450)
        XCTAssertEqual(scale.x(-10, width: 900), 0)
        XCTAssertEqual(scale.x(5_000, width: 900), 900)
        XCTAssertEqual(scale.x(.nan, width: 900), 0)
    }

    func testEndRulerLabelsAreNudgedInside() {
        let centres = Layout.rulerLabelCentres(
            [(x: 0.5, width: 36), (x: 305, width: 36), (x: 611, width: 36), (x: 915.5, width: 36)], width: 916)
        XCTAssertEqual(centres, [18, 305, 611, 898])
    }

    func testARulerLabelThatWouldOverlapIsDropped() {
        let centres = Layout.rulerLabelCentres([(x: 0, width: 40), (x: 30, width: 40), (x: 60, width: 40)], width: 80)
        XCTAssertEqual(centres, [20, nil, nil], "the last would sit at 60 and touch the first")
        XCTAssertEqual(Layout.rulerLabelCentres([(x: 0, width: 40)], width: 30), [nil])
    }

    func testALabelSitsRightOfItsTickAndNowRightOfItsLine() {
        let note = UUID()
        let placement = Layout.place(
            nowX: 737, nowLabelWidth: 22, ticks: [.init(id: note, x: 285, labelWidth: 110)], width: 916)
        XCTAssertEqual(placement.now, 745...767)
        XCTAssertEqual(placement.ticks, [note: 291])
    }

    func testALabelFlipsLeftWhenNowIsInItsWay() {
        let question = UUID()
        let placement = Layout.place(
            nowX: 737, nowLabelWidth: 22, ticks: [.init(id: question, x: 692, labelWidth: 150)], width: 916)
        XCTAssertEqual(placement.ticks, [question: 692 - 6 - 150])
    }

    func testNowFlipsLeftAtTheEndOfTheStripAndAlwaysShows() {
        XCTAssertEqual(Layout.place(nowX: 916, nowLabelWidth: 22, ticks: [], width: 916).now, 886...908)
        XCTAssertEqual(Layout.place(nowX: 10, nowLabelWidth: 22, ticks: [], width: 20).now, 0...22)
    }

    func testTheNewestTickWinsAndTheOlderOneHidesWhenNothingIsFree() {
        let older = UUID()
        let newer = UUID()
        let placement = Layout.place(
            nowX: 800, nowLabelWidth: 22,
            ticks: [.init(id: older, x: 100, labelWidth: 120), .init(id: newer, x: 110, labelWidth: 120)],
            width: 916)
        XCTAssertEqual(placement.ticks, [newer: 116], "the older label would overlap on the right and leave the strip on the left")
    }

    func testAnOlderTickTakesTheLeftSideOfANewerNeighbour() {
        let older = UUID()
        let newer = UUID()
        let placement = Layout.place(
            nowX: 800, nowLabelWidth: 22,
            ticks: [.init(id: older, x: 300, labelWidth: 120), .init(id: newer, x: 320, labelWidth: 120)],
            width: 916)
        XCTAssertEqual(placement.ticks, [newer: 326, older: 174])
    }

    func testLabelsKeepAGapAndStayInsideTheStrip() {
        let tick = UUID()
        // Right would end at 126, 2 pt short of now's label; left would start at -100.
        let hidden = Layout.place(
            nowX: 120, nowLabelWidth: 22, ticks: [.init(id: tick, x: 20, labelWidth: 100)], width: 916)
        XCTAssertEqual(hidden.ticks, [:])
        let shown = Layout.place(
            nowX: 122, nowLabelWidth: 22, ticks: [.init(id: tick, x: 20, labelWidth: 100)], width: 916)
        XCTAssertEqual(shown.ticks, [tick: 26], "exactly the 4 pt gap is enough")
    }
}
