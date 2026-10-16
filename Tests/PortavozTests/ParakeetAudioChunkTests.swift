import AVFoundation
import PortavozCore
import XCTest

@testable import TranscriptionKit

final class ParakeetAudioChunkTests: XCTestCase {
    func testNonFiniteSamplesBecomeSilenceWithoutChangingTheSampleCount() throws {
        let chunk = AudioChunk(
            channel: .microphone, samples: [0.25, .nan, -0.5, .infinity, -.infinity],
            sampleRate: 16_000, timestamp: 0)
        let buffer = try XCTUnwrap(chunk.pcmBuffer(), "A device glitch must not end the live session")
        XCTAssertEqual(buffer.frameLength, 5)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: 5))
        XCTAssertEqual(samples, [0.25, 0, -0.5, 0, 0])
    }

    func testInvalidSampleRateStillHasNoBuffer() {
        for rate in [0, -16_000, .nan] as [Double] {
            XCTAssertNil(AudioChunk(channel: .microphone, samples: [0.1], sampleRate: rate, timestamp: 0).pcmBuffer())
        }
    }
}
