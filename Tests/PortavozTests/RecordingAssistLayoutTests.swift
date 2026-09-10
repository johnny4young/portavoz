import Foundation
import XCTest

@testable import portavoz_app

/// The assist area was pinned at 260 pt while the captions took every flexible
/// point, so a taller window grew only the captions and eight panels shared one
/// scroll. These pin the split, the tab set and the single focus slot (D504).
final class RecordingAssistLayoutTests: XCTestCase {
    func testTheAssistAreaGrowsWithTheWindow() {
        let short = RecordingAssistLayout.split(total: 600, fraction: 0.42)
        let tall = RecordingAssistLayout.split(total: 1_000, fraction: 0.42)

        XCTAssertGreaterThan(
            tall.assist, short.assist,
            "a taller window must grow the assist area, not only the captions")
        XCTAssertGreaterThan(tall.captions, short.captions)
        XCTAssertEqual(
            short.captions + short.assist,
            600 - RecordingAssistLayout.dividerHeight,
            accuracy: 0.5,
            "the two zones plus the divider must fill the height")
        XCTAssertEqual(
            tall.captions + tall.assist,
            1_000 - RecordingAssistLayout.dividerHeight,
            accuracy: 0.5)
    }

    func testNeitherZoneCanBeSqueezedBelowItsFloor() {
        let allAssist = RecordingAssistLayout.split(total: 900, fraction: 5)
        XCTAssertGreaterThanOrEqual(
            allAssist.captions, RecordingAssistLayout.minimumCaptionsHeight)

        let allCaptions = RecordingAssistLayout.split(total: 900, fraction: -5)
        XCTAssertGreaterThanOrEqual(
            allCaptions.assist, RecordingAssistLayout.minimumAssistHeight)
    }

    func testAWindowTooShortForBothFloorsShrinksThemTogether() {
        let floors = RecordingAssistLayout.minimumCaptionsHeight
            + RecordingAssistLayout.minimumAssistHeight

        // Paying one floor in full drove the other to zero, and with several
        // banners stacked on a small window that meant no captions at all.
        // The sweep starts at the divider height, where the arithmetic used to
        // round its way to a negative frame.
        for step in stride(from: 0.0, through: 400.0, by: 0.5) {
            let total = RecordingAssistLayout.dividerHeight + CGFloat(step)
            let split = RecordingAssistLayout.split(total: total, fraction: 0.42)
            XCTAssertGreaterThanOrEqual(
                split.captions, 0, "negative caption height at \(total)")
            XCTAssertGreaterThanOrEqual(
                split.assist, 0, "negative assist height at \(total)")
            XCTAssertEqual(
                split.captions + split.assist,
                total - RecordingAssistLayout.dividerHeight,
                accuracy: 0.001,
                "the two zones must account for every usable point at \(total)")
        }

        // Above a couple of points, neither zone may vanish.
        for total in stride(from: CGFloat(20), through: floors, by: 5) {
            let split = RecordingAssistLayout.split(total: total, fraction: 0.42)
            XCTAssertGreaterThan(
                split.captions, 0,
                "the meeting's words must never be squeezed out at \(total)")
            XCTAssertGreaterThan(split.assist, 0, "total \(total)")
        }
    }

    func testANonFiniteHeightYieldsNothingRatherThanNaN() {
        let split = RecordingAssistLayout.split(total: .infinity, fraction: 0.42)

        XCTAssertEqual(split.captions, 0)
        XCTAssertEqual(split.assist, 0)
    }

    func testClampRejectsRunawayAndNonFiniteFractions() {
        XCTAssertEqual(RecordingAssistLayout.clamp(0.9), RecordingAssistLayout.maximumFraction)
        XCTAssertEqual(RecordingAssistLayout.clamp(0.01), RecordingAssistLayout.minimumFraction)
        XCTAssertEqual(RecordingAssistLayout.clamp(.nan), RecordingAssistLayout.defaultFraction)
    }

    func testDraggingTheDividerUpGrowsTheAssistArea() {
        let grown = RecordingAssistLayout.fraction(
            from: 0.42, draggedUpBy: 100, total: 1_000)
        let shrunk = RecordingAssistLayout.fraction(
            from: 0.42, draggedUpBy: -100, total: 1_000)

        XCTAssertGreaterThan(grown, 0.42)
        XCTAssertLessThan(shrunk, 0.42)
        XCTAssertEqual(
            RecordingAssistLayout.fraction(from: 0.42, draggedUpBy: 10_000, total: 1_000),
            RecordingAssistLayout.maximumFraction,
            "a long drag stops at the bound instead of collapsing the captions")
    }

    func testOptionalPanelsOnlyAppearOnceTheyCanShowSomething() {
        XCTAssertEqual(
            RecordingAssistTab.available(
                interviewEnabled: false, proactiveEnabled: false, hasSummary: false),
            [.companion, .objectives, .notes])
        XCTAssertEqual(
            RecordingAssistTab.available(
                interviewEnabled: true, proactiveEnabled: true, hasSummary: true),
            [.companion, .objectives, .notes, .interview, .proactive, .summary])
    }

    func testASelectionSurvivesItsTabDisappearing() {
        let available = RecordingAssistTab.available(
            interviewEnabled: false, proactiveEnabled: false, hasSummary: false)

        XCTAssertEqual(RecordingAssistTab.resolve(.notes, in: available), .notes)
        XCTAssertEqual(
            RecordingAssistTab.resolve(.summary, in: available), .companion,
            "a live summary that goes away must not leave a blank panel selected")
    }

    func testTheFocusSlotPrefersWhatTheUserIsWaitingFor() {
        let card = UUID()
        XCTAssertEqual(
            RecordingFocusSlot.resolve(
                hasCatchUp: true, directedCardID: card, hasNextQuestion: true),
            .catchUp,
            "the user pressed Catch me up seconds ago")
        XCTAssertEqual(
            RecordingFocusSlot.resolve(
                hasCatchUp: false, directedCardID: card, hasNextQuestion: true),
            .nextQuestion,
            "a card that also lives in the Companion tab must not eat the "
                + "suggestion the user just asked for")
        XCTAssertEqual(
            RecordingFocusSlot.resolve(
                hasCatchUp: false, directedCardID: card, hasNextQuestion: false),
            .directedCard(card))
        XCTAssertEqual(
            RecordingFocusSlot.resolve(
                hasCatchUp: false, directedCardID: nil, hasNextQuestion: false),
            .none)
    }
}
