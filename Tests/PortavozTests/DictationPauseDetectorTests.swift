import Foundation
import os
import PortavozCore
import XCTest

@testable import portavoz_app

final class DictationPauseDetectorTests: XCTestCase {
    private func chunk(_ index: Int) -> AudioChunk {
        AudioChunk(channel: .microphone, samples: [Float](repeating: 0.1, count: 4_096),
                   sampleRate: 16_000, timestamp: Double(index) * 0.256)
    }

    private func run(speech: Set<Int>, chunks: Int, failsAt: Int? = nil) async -> Int {
        struct Failure: Error {}
        let pauses = OSAllocatedUnfairLock(initialState: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let detector = DictationPauseDetector(pause: 1.5, load: {
            { _ in
                let index = calls.withLock { $0 += 1; return $0 - 1 }
                if index == failsAt { throw Failure() }
                return speech.contains(index)
            }
        }, onPause: { pauses.withLock { $0 += 1 } })
        for index in 0..<chunks { detector.offer(chunk(index)) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while calls.withLock({ $0 }) < chunks, pauses.withLock({ $0 }) == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(20))
        detector.cancel()
        return pauses.withLock { $0 }
    }

    func testAPauseAfterSpeechReportsOnceAndNeverBeforeSpeech() async {
        let afterSpeech = await run(speech: [0, 1, 2], chunks: 20)
        XCTAssertEqual(afterSpeech, 1, "1.5 s of silence after speech ends the dictation once")
        let shortPause = await run(speech: [0, 1, 2, 7, 8], chunks: 9)
        XCTAssertEqual(shortPause, 0, "a pause shorter than the setting keeps listening")
        let silenceOnly = await run(speech: [], chunks: 20)
        XCTAssertEqual(silenceOnly, 0, "silence before any speech never stops a dictation")
        let failing = await run(speech: [0, 1], chunks: 20, failsAt: 3)
        XCTAssertEqual(failing, 0, "a detector failure turns auto-stop off, never cuts early")
    }

    func testUnevaluatedAudioAndOverflowNeverStopEarly() async {
        let pauses = OSAllocatedUnfairLock(initialState: 0)
        let unevaluated = DictationPauseDetector(pause: 1.5, load: {
            { chunk in chunk.timestamp < 0.5 ? true : nil }
        }, onPause: { pauses.withLock { $0 += 1 } })
        for index in 0..<40 { unevaluated.offer(chunk(index)) }
        try? await Task.sleep(for: .milliseconds(200))
        unevaluated.cancel()
        XCTAssertEqual(pauses.withLock { $0 }, 0, "chunks with no detector frame are not silence")

        let overflowing = DictationPauseDetector(pause: 1.5, load: {
            try await Task.sleep(for: .milliseconds(100))
            // Speech sits among the newest chunks the bounded queue keeps.
            return { chunk in (25.6..<26.4).contains(chunk.timestamp) }
        }, onPause: { pauses.withLock { $0 += 1 } })
        for index in 0..<(DictationPauseDetector.capacity + 40) { overflowing.offer(chunk(index)) }
        try? await Task.sleep(for: .milliseconds(400))
        overflowing.cancel()
        XCTAssertEqual(pauses.withLock { $0 }, 0, "a dropped chunk turns auto-stop off for the session")
    }

    func testPauseSettingFallsBackToTheDefaultAndStaysOptIn() async throws {
        let suite = "auto-stop-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(DictationAutoStop.isEnabled(in: defaults))
        XCTAssertEqual(DictationAutoStop.pause(in: defaults), 2)
        defaults.set(7.5, forKey: DictationAutoStop.pauseKey)
        XCTAssertEqual(DictationAutoStop.pause(in: defaults), 2)
        defaults.set(3.0, forKey: DictationAutoStop.pauseKey)
        XCTAssertEqual(DictationAutoStop.pause(in: defaults), 3)
    }
}
