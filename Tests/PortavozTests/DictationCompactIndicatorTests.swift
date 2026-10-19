import Foundation
import XCTest

@testable import portavoz_app

final class DictationCompactIndicatorTests: XCTestCase {
    func testOnlyCaptureAndASuccessfulPasteShrinkTheStrip() throws {
        let suite = "compact-indicator-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(DictationCompactIndicator.applies(to: .listening, defaults: defaults), "off by default")

        defaults.set(true, forKey: DictationCompactIndicator.defaultsKey)
        for phase: DictationController.Phase in [.preparing, .listening, .delivering, .verified(3)] {
            XCTAssertTrue(DictationCompactIndicator.applies(to: phase, defaults: defaults), "\(phase)")
        }
        for phase: DictationController.Phase in [.idle, .noSpeech, .dispatched(3), .failed("x"), .recovery(.cancelled)] {
            XCTAssertFalse(DictationCompactIndicator.applies(to: phase, defaults: defaults),
                           "\(phase) needs the full panel's actions")
        }
    }

    func testElapsedTimeReadsAsMinutesAndSeconds() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(DictationCompactIndicator.elapsed(since: nil, now: start), "0:00")
        XCTAssertEqual(DictationCompactIndicator.elapsed(since: start, now: start.addingTimeInterval(7.9)), "0:07")
        XCTAssertEqual(DictationCompactIndicator.elapsed(since: start, now: start.addingTimeInterval(125)), "2:05")
        XCTAssertEqual(DictationCompactIndicator.elapsed(since: start, now: start.addingTimeInterval(-3)), "0:00")
    }
}
