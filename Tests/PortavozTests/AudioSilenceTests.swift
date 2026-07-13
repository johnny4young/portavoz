import XCTest

@testable import AudioCaptureKit

final class AudioSilenceTests: XCTestCase {
    func testPeakFindsLargestMagnitude() {
        XCTAssertEqual(AudioSilence.peak(of: [0.1, -0.7, 0.2]), 0.7, accuracy: 1e-6)
        XCTAssertEqual(AudioSilence.peak(of: []), 0)
    }

    func testDigitalSilenceIsSilent() {
        XCTAssertTrue(AudioSilence.isSilent([Float](repeating: 0, count: 480)))
        XCTAssertTrue(AudioSilence.isSilent([]))
    }

    func testFaintNoiseBelowFloorIsSilent() {
        // −80 dBFS ≈ 0.0001 linear, well under the −60 dBFS floor.
        XCTAssertTrue(AudioSilence.isSilent([0.0001, -0.0001, 0.00005]))
    }

    func testRealSpeechIsNotSilent() {
        XCTAssertFalse(AudioSilence.isSilent([0.5, -0.3, 0.2]))
        // −40 dBFS ≈ 0.01, comfortably above the floor.
        XCTAssertFalse(AudioSilence.isSilent([0.01, -0.012]))
    }
}
