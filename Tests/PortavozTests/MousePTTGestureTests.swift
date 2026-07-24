import TranscriptionKit
import XCTest

final class MousePTTGestureTests: XCTestCase {
    func testPressStartsWhenIdleAndFinishesWhenListening() {
        XCTAssertEqual(
            MousePTTGesture.action(
                for: .press, isListening: false, mouseOwnsSession: false),
            .start)
        // Pressing during a hotkey-started session acts as the finish
        // gesture — one physical control always ends capture.
        XCTAssertEqual(
            MousePTTGesture.action(
                for: .press, isListening: true, mouseOwnsSession: false),
            .finish)
    }

    func testReleaseDeliversOnlyForTheSessionTheButtonStarted() {
        XCTAssertEqual(
            MousePTTGesture.action(
                for: .release, isListening: true, mouseOwnsSession: true),
            .finish)
        // A hotkey session must not be ended by a stray button release.
        XCTAssertEqual(
            MousePTTGesture.action(
                for: .release, isListening: true, mouseOwnsSession: false),
            .ignore)
    }

    func testReleaseAfterTheSessionEndedIsInert() {
        // The press already finished the session (or it failed): its
        // matching release arrives with listening off and must do nothing,
        // whoever owned the session.
        for owns in [true, false] {
            XCTAssertEqual(
                MousePTTGesture.action(
                    for: .release, isListening: false, mouseOwnsSession: owns),
                .ignore)
        }
    }
}
