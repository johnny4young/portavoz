import Foundation
import XCTest

@testable import portavoz_app

/// The assist area was pinned at 260 pt while the captions took every flexible
/// point, so a taller window grew only the captions and eight panels shared one
/// scroll. These pin the split, the tab set and the single focus slot (D504).
final class RecordingAssistLayoutTests: XCTestCase {
    func testAReplacedCardCountsAsUnreadUntilTheCompanionTabShowsIt() {
        let kept = UUID()
        let replaced = UUID()
        let replacement = UUID()
        var unread = RecordingAssistUnread()
        unread.observe([kept, replaced], showingCompanion: true)

        unread.observe([kept, replacement], showingCompanion: false)

        XCTAssertEqual(
            unread.count(in: [kept, replacement]), 1,
            "a replacement is unread even when the number of cards stays unchanged")

        unread.markSeen([kept, replacement])

        XCTAssertEqual(unread.count(in: [kept, replacement]), 0)
    }

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

    func testAShortWindowKeepsTheAssistFloorWhileOneClearCaptionLineFits() {
        typealias Layout = RecordingAssistLayout
        let floors = Layout.minimumCaptionsHeight + Layout.minimumAssistHeight
        let compact = Layout.compactCaptionsHeight + Layout.minimumAssistHeight
        for usable in stride(from: compact, to: floors, by: 1) {
            let split = Layout.split(total: usable + Layout.dividerHeight, fraction: 0.42)
            XCTAssertEqual(split.assist, Layout.minimumAssistHeight, "usable \(usable)")
            XCTAssertGreaterThanOrEqual(split.captions, Layout.compactCaptionsHeight)
        }
        var previous = Layout.split(total: Layout.dividerHeight + 1, fraction: 0.42)
        for usable in stride(from: CGFloat(2), to: compact, by: 1) {
            let split = Layout.split(total: usable + Layout.dividerHeight, fraction: 0.42)
            let share = usable * Layout.minimumCaptionsHeight / floors
            XCTAssertGreaterThanOrEqual(
                split.captions, min(Layout.compactCaptionsHeight, share) - 0.001,
                "below one clear line the captions keep their proportional share at \(usable)")
            XCTAssertLessThanOrEqual(split.assist - previous.assist, 2, "no jump at \(usable)")
            XCTAssertLessThanOrEqual(split.captions - previous.captions, 2, "no jump at \(usable)")
            previous = split
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

    func testTheAssistAreaKeepsThreeTabsLedByApuntador() {
        XCTAssertEqual(RecordingAssistTab.allCases, [.companion, .objectives, .notes])
    }

    func testVoicesAndThePanelShareARowOnlyWhenBothFit() {
        let needed = RecordingStageLayout.minimumVoicesWidth + RecordingStageLayout.columnGap
            + RecordingStageLayout.panelWidth + 2 * RecordingStageLayout.horizontalPadding
        XCTAssertTrue(RecordingStageLayout.isSideBySide(width: needed))
        XCTAssertFalse(RecordingStageLayout.isSideBySide(width: needed - 1))
        XCTAssertFalse(
            RecordingStageLayout.isSideBySide(width: 900 - 232),
            "the narrowest window stacks the panel under the captions")
    }

    func testAShortStageFoldsVoiceRowsBeforeTheCaptionsLoseTheirFloor() {
        typealias Layout = RecordingStageLayout
        // A 1024 x 768 display leaves the stage about 400 pt: six rows left the captions nothing.
        XCTAssertEqual(Layout.voices(height: 400, sideBySide: true), .rows(3))
        XCTAssertEqual(Layout.voices(height: .infinity, sideBySide: true), .rows(3))
        // Beside the panel only the strip and the captions sit under the table.
        XCTAssertEqual(Layout.voices(height: 474, sideBySide: true), .rows(6))
        XCTAssertEqual(Layout.voices(height: 473, sideBySide: true), .rows(5))
        XCTAssertEqual(Layout.voices(height: 700, sideBySide: false), .rows(6))
        XCTAssertEqual(Layout.voices(height: 699, sideBySide: false), .rows(5))
    }

    func testAStackedStageTooShortForTheTableShowsOnlyWhoLeads() {
        typealias Layout = RecordingStageLayout
        XCTAssertEqual(Layout.voices(height: 550, sideBySide: false), .rows(1))
        XCTAssertEqual(Layout.voices(height: 549, sideBySide: false), .leadOnly)
        XCTAssertEqual(Layout.voices(height: 430, sideBySide: false), .leadOnly)
        XCTAssertEqual(Layout.voices(height: 0, sideBySide: false), .leadOnly)
        XCTAssertEqual(Layout.voices(height: .nan, sideBySide: false), .leadOnly)
    }

    func testAShortStageLowersTheSharedRowInsteadOfOverflowing() {
        XCTAssertEqual(
            RecordingStageLayout.rowMinimumHeight(height: 1_000), RecordingStageLayout.panelMinimumHeight)
        XCTAssertEqual(RecordingStageLayout.rowMinimumHeight(height: 400), 172)
        XCTAssertEqual(RecordingStageLayout.rowMinimumHeight(height: 100), 0)
    }

    func testThePanelKeepsTheBoardShareOfAWideRow() {
        XCTAssertEqual(RecordingStageLayout.panelWidth(for: 800), RecordingStageLayout.panelWidth)
        XCTAssertEqual(RecordingStageLayout.panelWidth(for: 1662), 551)
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
