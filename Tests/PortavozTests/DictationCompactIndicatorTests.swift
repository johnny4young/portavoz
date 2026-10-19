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
        for phase: DictationController.Phase in [.preparing, .listening, .delivering, .verified(3), .dispatched(3)] {
            XCTAssertTrue(DictationCompactIndicator.applies(to: phase, defaults: defaults), "\(phase)")
        }
        for phase: DictationController.Phase in [.idle, .noSpeech, .failed("x"), .recovery(.cancelled)] {
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

final class DictationWaveformTests: XCTestCase {
    func testSilenceStaysAFlatLineAndLoudSpeechFillsTheHeight() {
        XCTAssertEqual(DictationWaveform.amplitude(for: 0), 0.04, "silence keeps a visible line")
        XCTAssertEqual(DictationWaveform.amplitude(for: 0.000_5), 0.04, accuracy: 0.000_1)
        XCTAssertEqual(DictationWaveform.amplitude(for: 0.031_6), 0.5, accuracy: 0.01, "−30 dB is half height")
        XCTAssertEqual(DictationWaveform.amplitude(for: 2), 1, "clipped input never overflows")
    }

    func testEveryWaveMeetsTheCenterAtBothEndsAndStaysInBounds() {
        for wave in DictationWaveform.waves {
            XCTAssertEqual(DictationWaveform.offset(at: 0, time: 3.7, wave: wave, amplitude: 1), 0, accuracy: 1e-9)
            XCTAssertEqual(DictationWaveform.offset(at: 1, time: 3.7, wave: wave, amplitude: 1), 0, accuracy: 1e-9)
            for step in 0...20 {
                let y = DictationWaveform.offset(at: Double(step) / 20, time: 1.3, wave: wave, amplitude: 1)
                XCTAssertLessThanOrEqual(abs(y), 1)
            }
        }
        let moving = DictationWaveform.waves[0]
        XCTAssertNotEqual(
            DictationWaveform.offset(at: 0.4, time: 0, wave: moving, amplitude: 1),
            DictationWaveform.offset(at: 0.4, time: 0.2, wave: moving, amplitude: 1),
            "the waves move over time")
    }
}
