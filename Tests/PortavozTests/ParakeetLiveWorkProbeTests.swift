import Foundation
import os
import PortavozCore
import XCTest
@testable import TranscriptionKit

final class ParakeetLiveWorkProbeTests: XCTestCase {
    func testCountsObservableWorkAndSeparatesDrainPhasesWithoutContent() throws {
        let clock = OSAllocatedUnfairLock(initialState: Duration.zero)
        let probe = ParakeetLiveWorkProbe(now: { clock.withLock { $0 } })
        clock.withLock { $0 = .milliseconds(10) }
        probe.begin(.feed)
        probe.input(frames: 1_600, sampleRate: 16_000, channel: .microphone, accepted: true)
        probe.input(frames: 12, sampleRate: 16_000, channel: .microphone, accepted: false)
        probe.update(tokens: 3, timings: 2, confirmed: false)
        clock.withLock { $0 = .milliseconds(110) }
        probe.begin(.finish)
        probe.update(tokens: 4, timings: 4, confirmed: true)
        clock.withLock { $0 = .milliseconds(130) }
        probe.begin(.updateDrain)
        probe.update(tokens: 2, timings: 1, confirmed: false)
        clock.withLock { $0 = .milliseconds(135) }
        probe.begin(.cleanup)
        clock.withLock { $0 = .milliseconds(142) }
        let sample = try XCTUnwrap(probe.finish(outcome: .completed))
        XCTAssertTrue(sample.valid)
        XCTAssertEqual(sample.channel, .microphone)
        XCTAssertEqual(sample.sampleRate, 16_000)
        XCTAssertEqual(sample.inputChunks, 1)
        XCTAssertEqual(sample.inputFrames, 1_600)
        XCTAssertEqual(sample.rejectedBuffers, 1)
        XCTAssertEqual(sample.backendUpdates, 3)
        XCTAssertEqual(sample.backendTokens, 9)
        XCTAssertEqual(sample.backendTokenTimings, 7)
        XCTAssertEqual(sample.confirmedUpdates, 1)
        XCTAssertEqual(sample.updatesAfterFinishStarted, 2)
        XCTAssertEqual(sample.finishCalls, 1)
        XCTAssertEqual(sample.loadMilliseconds, 10)
        XCTAssertEqual(sample.feedMilliseconds, 100)
        XCTAssertEqual(sample.finishMilliseconds, 20)
        XCTAssertEqual(sample.updateDrainMilliseconds, 5)
        XCTAssertEqual(sample.cleanupMilliseconds, 7)
        let data = try JSONEncoder().encode(sample)
        XCTAssertEqual(try JSONDecoder().decode(ParakeetLiveWorkSample.self, from: data), sample)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.compactMap { $0.value is String ? $0.key : nil }), ["channel", "outcome"])
        XCTAssertFalse(object.keys.contains("tokenIds"))
        XCTAssertFalse(object.keys.contains("text"))
    }

    func testTerminalSampleIsSealedOnceEvenIfLateUpdatesArrive() throws {
        let probe = ParakeetLiveWorkProbe()
        let sample = try XCTUnwrap(probe.finish(outcome: .cancelled))
        probe.update(tokens: 99, timings: 99, confirmed: true)
        probe.input(frames: 99, sampleRate: 16_000, channel: .system, accepted: true)
        probe.begin(.finish)
        XCTAssertNil(probe.finish(outcome: .completed))
        XCTAssertEqual(sample.outcome, .cancelled)
        XCTAssertEqual(sample.backendUpdates, 0)
    }

    func testConcurrentUpdatesDoNotLoseCounts() async throws {
        let probe = ParakeetLiveWorkProbe()
        probe.begin(.feed)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    for _ in 0..<100 {
                        probe.update(tokens: 2, timings: 1, confirmed: true)
                    }
                }
            }
        }
        let sample = try XCTUnwrap(probe.finish(outcome: .failed))
        XCTAssertTrue(sample.valid)
        XCTAssertEqual(sample.backendUpdates, 1_600)
        XCTAssertEqual(sample.backendTokens, 3_200)
        XCTAssertEqual(sample.confirmedUpdates, 1_600)
    }

    func testInvalidGeometryOverflowAndChannelChangesCannotLookValid() throws {
        for rate in [Double.nan, .infinity, 0, -1] {
            let probe = ParakeetLiveWorkProbe()
            probe.input(frames: 1, sampleRate: rate, channel: .microphone, accepted: true)
            XCTAssertFalse(try XCTUnwrap(probe.finish(outcome: .failed)).valid)
        }
        let probe = ParakeetLiveWorkProbe()
        probe.input(frames: .max, sampleRate: 16_000, channel: .microphone, accepted: true)
        probe.input(frames: 1, sampleRate: 48_000, channel: .system, accepted: true)
        probe.update(tokens: .max, timings: -1, confirmed: false)
        probe.update(tokens: 1, timings: 0, confirmed: false)
        let sample = try XCTUnwrap(probe.finish(outcome: .failed))
        XCTAssertFalse(sample.valid)
        XCTAssertEqual(sample.inputFrames, .max)
        XCTAssertEqual(sample.backendTokens, .max)
        let negative = ParakeetLiveWorkProbe()
        negative.input(frames: -1, sampleRate: 16_000, channel: .microphone, accepted: true)
        XCTAssertFalse(try XCTUnwrap(negative.finish(outcome: .failed)).valid)
    }

    func testIncompleteCompletionAndBackwardClockOrPhaseAreInvalid() throws {
        let incomplete = ParakeetLiveWorkProbe()
        XCTAssertFalse(try XCTUnwrap(incomplete.finish(outcome: .completed)).valid)
        let clock = OSAllocatedUnfairLock(initialState: Duration.seconds(2))
        let probe = ParakeetLiveWorkProbe(now: { clock.withLock { $0 } })
        clock.withLock { $0 = .seconds(1) }
        probe.begin(.feed)
        probe.begin(.load)
        XCTAssertFalse(try XCTUnwrap(probe.finish(outcome: .failed)).valid)
    }
}
