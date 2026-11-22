import SwiftUI
import XCTest

@testable import portavoz_app

@MainActor
final class PVMotionTests: XCTestCase {
    func testReduceMotionDropsTheAnimationAndKeepsItOtherwise() async {
        let easing = Animation.easeInOut(duration: 0.6)
        XCTAssertNil(PVMotion.resolved(easing, reduceMotion: true))
        XCTAssertEqual(PVMotion.resolved(easing, reduceMotion: false), easing)
    }

    func testAChangeWithoutMotionStillLandsAndCompletesAtOnce() async {
        for (animation, reduceMotion) in [(Animation.easeInOut, true), (nil, false)] {
            var applied = 0
            var completed = 0
            PVMotion.perform(animation, reduceMotion: reduceMotion) {
                applied += 1
            } completion: {
                completed += 1
            }
            XCTAssertEqual(applied, 1)
            XCTAssertEqual(completed, 1, "a scroll trace must close even when nothing animates")
        }
    }

    func testTheLiveDotHoldsSolidUnderReduceMotion() async {
        XCTAssertEqual(RecordingLiveDot.opacity(elapsed: 2, reduceMotion: false), 1)
        XCTAssertEqual(RecordingLiveDot.opacity(elapsed: 3, reduceMotion: false), 0.35)
        XCTAssertEqual(RecordingLiveDot.opacity(elapsed: 3, reduceMotion: true), 1)
    }

    func testIdleFirstListenBarsAreFlatWithoutAPhase() async {
        let bars = (0..<FirstListenWaveform.barCount).map {
            FirstListenWaveform.height($0, level: 0, active: false, phase: nil)
        }
        XCTAssertEqual(Set(bars).count, 1, "idle bars hold still under Reduce Motion")

        let rippling = (0..<FirstListenWaveform.barCount).map {
            FirstListenWaveform.height($0, level: 0, active: false, phase: 1)
        }
        XCTAssertGreaterThan(Set(rippling).count, 1)

        let middle = FirstListenWaveform.barCount / 2
        XCTAssertEqual(
            FirstListenWaveform.height(middle, level: 0.8, active: true, phase: nil),
            FirstListenWaveform.height(middle, level: 0.8, active: true, phase: 3),
            "live bars follow the level, never the clock")
    }
}
