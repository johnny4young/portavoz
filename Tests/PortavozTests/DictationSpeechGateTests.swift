import Foundation
import os
import PortavozCore
import XCTest

@testable import portavoz_app
@testable import TranscriptionKit

final class DictationSpeechGateTests: XCTestCase {
    private func chunk(_ index: Int = 0) -> AudioChunk {
        AudioChunk(channel: .microphone, samples: [Float](repeating: 0.1, count: 4_096),
                   sampleRate: 16_000, timestamp: Double(index) * 0.256)
    }

    func testCompletePassWithoutSpeechIsNoSpeech() async {
        let gate = DictationSpeechGate { { _ in false } }
        for index in 0..<10 { gate.offer(chunk(index)) }
        let verdict = await gate.verdict(within: .seconds(2))
        XCTAssertEqual(verdict, .noSpeech)
    }

    func testFirstSpeechDecidesAndLaterAudioIsNotAnalyzed() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let gate = DictationSpeechGate {
            { _ in calls.withLock { $0 += 1; return $0 == 3 } }
        }
        for index in 0..<3 { gate.offer(chunk(index)) }
        let speech = await waitUntil { calls.withLock { $0 } == 3 }
        XCTAssertTrue(speech)
        for index in 3..<20 { gate.offer(chunk(index)) }
        let verdict = await gate.verdict(within: .seconds(2))
        XCTAssertEqual(verdict, .speech)
        XCTAssertEqual(calls.withLock { $0 }, 3, "Speech ends the analysis")
    }

    func testEveryFailureModeFailsOpen() async {
        struct Failure: Error {}
        let unavailable = DictationSpeechGate { throw Failure() }
        unavailable.offer(chunk())
        let unavailableVerdict = await unavailable.verdict(within: .seconds(2))
        XCTAssertEqual(unavailableVerdict, .undetermined, "A missing model is not silence")

        let failing = DictationSpeechGate { { _ in throw Failure() } }
        failing.offer(chunk())
        let failingVerdict = await failing.verdict(within: .seconds(2))
        XCTAssertEqual(failingVerdict, .undetermined, "A detector error is not silence")

        let cancelled = DictationSpeechGate { { _ in false } }
        cancelled.offer(chunk())
        cancelled.cancel()
        let cancelledVerdict = await cancelled.verdict(within: .seconds(2))
        XCTAssertEqual(cancelledVerdict, .undetermined)
    }

    func testDroppedAudioForfeitsTheNoSpeechVerdict() async {
        let release = OSAllocatedUnfairLock(initialState: false)
        let gate = DictationSpeechGate {
            while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
            return { _ in false }
        }
        for index in 0...DictationSpeechGate.capacity { gate.offer(chunk(index)) }
        release.withLock { $0 = true }
        let verdict = await gate.verdict(within: .seconds(5))
        XCTAssertEqual(verdict, .undetermined, "Audio the detector never saw cannot prove silence")
    }

    func testSlowAnalysisTimesOutAsUndetermined() async {
        let gate = DictationSpeechGate {
            { _ in
                try await Task.sleep(for: .seconds(30))
                return false
            }
        }
        gate.offer(chunk())
        let start = ContinuousClock.now
        let verdict = await gate.verdict(within: .milliseconds(100))
        XCTAssertEqual(verdict, .undetermined)
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

@MainActor
final class DictationSpeechGateSileroTests: XCTestCase {
    private func batch(_ probability: Float, triggered: Bool = false) -> VoiceActivityBatch {
        VoiceActivityBatch(didResetForDiscontinuity: false, observations: [
            VoiceActivityObservation(frameStart: 0, frameEnd: 0.256, speechProbability: probability,
                                     isSpeechActive: triggered, event: nil)
        ])
    }

    func testQuietSpeechCountsFromSileroReferenceThreshold() async {
        XCTAssertTrue(DictationSpeechGate.heardSpeech(batch(0.6)), "Below FluidAudio's 0.85 is still speech")
        XCTAssertTrue(DictationSpeechGate.heardSpeech(batch(0.5)))
        XCTAssertTrue(DictationSpeechGate.heardSpeech(batch(0.2, triggered: true)), "A triggered frame is speech")
        XCTAssertFalse(DictationSpeechGate.heardSpeech(batch(0.49)))
        XCTAssertFalse(DictationSpeechGate.heardSpeech(VoiceActivityBatch(didResetForDiscontinuity: true, observations: [])))
    }

    func testGateIsOnUnlessTheUserTurnedItOff() async throws {
        let suite = "speech-gate-default-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(DictationSpeechGate.isEnabled(in: defaults))
        defaults.set(false, forKey: DictationSpeechGate.defaultsKey)
        XCTAssertFalse(DictationSpeechGate.isEnabled(in: defaults))
    }

    func testTurningOnDictationPreparesTheDetectorOnlyWhenTheGateIsOn() async throws {
        let suite = "speech-gate-prepare-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: DictationSpeechGate.defaultsKey)
        let services = try AppServices(arguments: ["-use-temp-store"], environment: [:], defaults: defaults)
        await services.prepareSpeechGateIfEnabled()
        XCTAssertEqual(services.speechGateModel, .unknown, "A gate turned off never reaches the installer")
        defaults.removeObject(forKey: DictationSpeechGate.defaultsKey)
        await services.prepareSpeechGateIfEnabled()
        // The disposable composition reports missing instead of downloading.
        XCTAssertEqual(services.speechGateModel, .missing)
    }

    func testDisposableCompositionNeverDownloadsTheDetector() async throws {
        let services = try AppServices(arguments: ["-use-temp-store"], environment: [:])
        await services.installSpeechGateModel()
        XCTAssertEqual(services.speechGateModel, .missing)
    }
}
