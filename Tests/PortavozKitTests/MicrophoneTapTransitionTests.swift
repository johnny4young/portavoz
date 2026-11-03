import AVFAudio
import Foundation
import XCTest

@testable import AudioCaptureKit

@MainActor
final class MicrophoneTapTransitionTests: XCTestCase {
    func testIdentityIntervalEndsThePreviousConversionPhase() async throws {
        let chunks = try await deliver([
            (24_000, [-1, 1], false), (48_000, [10, 11], false), (24_000, [20, 21], false)
        ])
        XCTAssertEqual(chunks, [[-1, 0, 1], [10, 11], [20, 20.5, 21]])
    }

    func testRateFlipWithoutGraphNotificationStartsWithTheNewDevice() async throws {
        let chunks = try await deliver([(24_000, [-1, 1], false), (12_000, [10, 11], false)])
        XCTAssertEqual(chunks, [[-1, 0, 1], [10, 10.25, 10.5, 10.75, 11]])
    }

    func testTinyDownsampleToUpsampleTransitionCannotDropTheNewInput() async throws {
        let chunks = try await deliver([(96_000, [1], false), (16_000, [9], false)])
        XCTAssertEqual(chunks, [[1], [9]])
    }

    func testMuteDiscardsPriorVoiceWithoutResettingTheTimelinePhase() async throws {
        let chunks = try await deliver([
            (24_000, [-1, 1], false), (24_000, [9, 9], true), (24_000, [20, 21], false)
        ])
        XCTAssertEqual(chunks, [[-1, 0, 1], [0, 0, 0, 0], [10, 20, 20.5, 21]])
    }

    private func deliver(_ steps: [(Double, [Float], Bool)]) async throws -> [[Float]] {
        let source = MicrophoneSource()
        let delivery = CaptureDeliveryBuffer(channel: .microphone)
        // This is the block installTap hands to AVAudioEngine, not a policy surrogate.
        let callback = source.makeInputTap(target: 48_000, continuation: delivery)
        for (rate, samples, muted) in steps {
            source.setMuted(muted)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
            buffer.frameLength = AVAudioFrameCount(samples.count)
            let channel = try XCTUnwrap(buffer.floatChannelData).pointee
            for (index, sample) in samples.enumerated() { channel[index] = sample }
            callback(buffer, AVAudioTime(hostTime: 100))
        }
        delivery.finish()
        var chunks: [[Float]] = []
        for try await chunk in delivery.stream() {
            XCTAssertEqual(chunk.sampleRate, 48_000)
            chunks.append(chunk.samples)
        }
        XCTAssertNil(delivery.report().failure)
        XCTAssertEqual(delivery.report().paddingFrames, 0)
        return chunks
    }
}
