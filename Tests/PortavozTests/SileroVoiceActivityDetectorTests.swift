import FluidAudio
import Foundation
import ModelStoreKit
import PortavozCore
import XCTest

@testable import TranscriptionKit

final class SileroVoiceActivityDetectorTests: XCTestCase {
    func testUnevenInputReachesStrictFramesWithoutLosingSamples() async throws {
        let spy = VoiceActivityFrameSpy()
        let detector = makeDetector(spy: spy)
        let input = (0..<8_192).map { Float($0) / 8_192 }
        for index in 0..<16 {
            let samples = Array(input[(index * 512)..<((index + 1) * 512)])
            let result = try await detector.process(AudioChunk(
                channel: .microphone, samples: samples, sampleRate: 16_000,
                timestamp: Double(index * 512) / 16_000))
            XCTAssertEqual(result.observations.count, index == 7 || index == 15 ? 1 : 0)
            XCTAssertFalse(result.didResetForDiscontinuity)
        }
        let frames = await spy.frames
        XCTAssertEqual(frames.map(\.count), [4_096, 4_096])
        XCTAssertEqual(frames.flatMap { $0 }, input)
    }

    func testRateChangeAndTimestampGapResetModelContextInsteadOfInventingSilence() async throws {
        let spy = VoiceActivityFrameSpy()
        let detector = makeDetector(spy: spy)
        let at48K = [Float](repeating: 0.25, count: 12_288)
        let first = try await detector.process(AudioChunk(
            channel: .microphone, samples: at48K, sampleRate: 48_000, timestamp: 0))
        XCTAssertFalse(first.didResetForDiscontinuity)
        XCTAssertEqual(first.observations.count, 1)
        XCTAssertEqual(first.observations[0].frameEnd, 0.256, accuracy: 0.000_001)

        let gap = try await detector.process(AudioChunk(
            channel: .microphone, samples: at48K, sampleRate: 48_000, timestamp: 2))
        XCTAssertTrue(gap.didResetForDiscontinuity)
        XCTAssertEqual(gap.observations.count, 1)
        XCTAssertEqual(gap.observations[0].frameStart, 2, accuracy: 0.000_001)

        let changedRate = try await detector.process(AudioChunk(
            channel: .microphone, samples: [Float](repeating: 0.5, count: 4_096),
            sampleRate: 16_000, timestamp: 2.256))
        XCTAssertTrue(changedRate.didResetForDiscontinuity)
        XCTAssertEqual(changedRate.observations[0].frameStart, 2.256, accuracy: 0.000_001)
        let frameCount = await spy.frames.count
        XCTAssertEqual(frameCount, 3)
    }

    func testOneMissingSmallPacketResetsBeforeASilenceCountdownCouldAdvance() async throws {
        let detector = makeDetector(spy: VoiceActivityFrameSpy())
        let packet = [Float](repeating: 0.2, count: 512)
        _ = try await detector.process(AudioChunk(
            channel: .microphone, samples: packet, sampleRate: 16_000,
            timestamp: 0))
        let afterLoss = try await detector.process(AudioChunk(
            channel: .microphone, samples: packet, sampleRate: 16_000,
            timestamp: 0.064))
        XCTAssertTrue(afterLoss.didResetForDiscontinuity)
        XCTAssertTrue(afterLoss.observations.isEmpty)
    }

    func testEmptyAndInvalidChunksCannotAdvanceTheStream() async throws {
        let spy = VoiceActivityFrameSpy()
        let detector = makeDetector(spy: spy)
        let empty = try await detector.process(AudioChunk(
            channel: .microphone, samples: [], sampleRate: 44_100, timestamp: 50))
        XCTAssertTrue(empty.observations.isEmpty)
        XCTAssertFalse(empty.didResetForDiscontinuity)

        for bad in [Double.nan, .infinity, 0, -1] {
            await assertThrowsAsync {
                try await detector.process(AudioChunk(
                    channel: .microphone, samples: [0], sampleRate: bad, timestamp: 0))
            }
        }
        await assertThrowsAsync {
            try await detector.process(AudioChunk(
                channel: .system, samples: [0], sampleRate: 16_000, timestamp: 0))
        }
        await assertThrowsAsync {
            try await detector.process(AudioChunk(
                channel: .microphone, samples: [Float.nan], sampleRate: 16_000,
                timestamp: 0))
        }
        let frames = await spy.frames
        XCTAssertTrue(frames.isEmpty)
    }

    func testInferenceFailureDoesNotCommitInputOrSileroState() async throws {
        let spy = VoiceActivityFrameSpy(failFirst: true)
        let detector = makeDetector(spy: spy)
        let chunk = AudioChunk(
            channel: .microphone, samples: [Float](repeating: 0.5, count: 4_096),
            sampleRate: 16_000, timestamp: 0)
        await assertThrowsAsync { try await detector.process(chunk) }
        let recovered = try await detector.process(chunk)
        XCTAssertEqual(recovered.observations.count, 1)
        XCTAssertEqual(recovered.observations[0].frameStart, 0)
        let inputStates = await spy.inputStates
        XCTAssertEqual(inputStates, [0, 0])
    }

    func testConcurrentProducerCannotInterleaveOneModelState() async throws {
        let hold = VoiceActivityInferenceHold()
        let (started, signal) = AsyncStream.makeStream(of: Void.self)
        let detector = SileroVoiceActivityDetector(channel: .microphone) { frame, state in
            signal.yield(())
            await hold.wait()
            var next = state
            next.processedSamples += frame.count
            return VadStreamResult(state: next, event: nil, probability: 0.01)
        }
        let chunk = AudioChunk(
            channel: .microphone, samples: [Float](repeating: 0, count: 4_096),
            sampleRate: 16_000, timestamp: 0)
        let first = Task { try await detector.process(chunk) }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        do {
            _ = try await detector.process(chunk)
            XCTFail("A second producer must not interleave the pending inference")
        } catch VoiceActivityDetectionError.concurrentUse {
        } catch {
            XCTFail("Unexpected rejection: \(error)")
        }
        await hold.release()
        let firstResult = try await first.value
        XCTAssertEqual(firstResult.observations.count, 1)
    }

    func testCancellationDuringInferenceDoesNotCommitAFinishedModelResult() async throws {
        let hold = VoiceActivityInferenceHold()
        let (started, signal) = AsyncStream.makeStream(of: Void.self)
        let detector = SileroVoiceActivityDetector(channel: .microphone) { frame, state in
            signal.yield(())
            await hold.wait()
            var next = state
            next.processedSamples += frame.count
            return VadStreamResult(state: next, event: nil, probability: 0.01)
        }
        let chunk = AudioChunk(
            channel: .microphone, samples: [Float](repeating: 0, count: 4_096),
            sampleRate: 16_000, timestamp: 0)
        let first = Task { try await detector.process(chunk) }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        first.cancel()
        await hold.release()
        do {
            _ = try await first.value
            XCTFail("Cancelled inference must not publish its late model result")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected cancellation failure: \(error)")
        }
        let retried = try await detector.process(chunk)
        XCTAssertEqual(retried.observations.count, 1)
        XCTAssertEqual(retried.observations[0].frameStart, 0)
    }

    func testRealSileroModelRejectsExactDigitalSilenceWhenInstalled() async throws {
        guard let root = ProcessInfo.processInfo.environment["PORTAVOZ_TEST_SILERO_MODEL_ROOT"] else {
            throw XCTSkip("Install the pinned Silero fixture for this real-model lane")
        }
        let store = ModelStore(rootDirectory: URL(fileURLWithPath: root))
        let detector = try await SileroVoiceActivityDetector.load(
            from: store, channel: .microphone)
        let result = try await detector.process(AudioChunk(
            channel: .microphone, samples: [Float](repeating: 0, count: 16_384),
            sampleRate: 16_000, timestamp: 0))
        XCTAssertEqual(result.observations.count, 4)
        XCTAssertTrue(result.observations.allSatisfy { $0.speechProbability < 0.85 })
        XCTAssertTrue(result.observations.allSatisfy { !$0.isSpeechActive && $0.event == nil })
    }

    func testMissingModelFailsClosedWithoutImplicitDownload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-silero-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await SileroVoiceActivityDetector.load(
                from: ModelStore(rootDirectory: root), channel: .microphone)
            XCTFail("A missing model must not trigger FluidAudio ModelHub")
        } catch VoiceActivityDetectionError.modelNotInstalled {
        } catch {
            XCTFail("Unexpected model setup failure: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRealSileroModelFindsSpeechInPublicFixtureWhenInstalled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["PORTAVOZ_TEST_SILERO_MODEL_ROOT"],
              let audioPath = environment["PORTAVOZ_TEST_SILERO_SPEECH_WAV"]
        else { throw XCTSkip("Install the pinned Silero model and public speech fixture") }

        let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: audioPath))
        XCTAssertGreaterThan(samples.count, 16_000)
        let detector = try await SileroVoiceActivityDetector.load(
            from: ModelStore(rootDirectory: URL(fileURLWithPath: root)),
            channel: .microphone)
        var observations: [VoiceActivityObservation] = []
        for start in stride(from: 0, to: samples.count, by: 4_096) {
            let end = min(start + 4_096, samples.count)
            let batch = try await detector.process(AudioChunk(
                channel: .microphone,
                samples: Array(samples[start..<end]),
                sampleRate: 16_000,
                timestamp: Double(start) / 16_000))
            XCTAssertFalse(batch.didResetForDiscontinuity)
            observations += batch.observations
        }
        XCTAssertTrue(observations.contains { observation in
            if case .speechStart = observation.event { return true }
            return false
        })
        XCTAssertTrue(observations.contains { $0.isSpeechActive })
    }

    private func makeDetector(spy: VoiceActivityFrameSpy) -> SileroVoiceActivityDetector {
        SileroVoiceActivityDetector(channel: .microphone) { frame, state in
            try await spy.infer(frame, state: state)
        }
    }
}

private actor VoiceActivityFrameSpy {
    private(set) var frames: [[Float]] = []
    private(set) var inputStates: [Int] = []
    private var failFirst: Bool

    init(failFirst: Bool = false) {
        self.failFirst = failFirst
    }

    func infer(_ frame: [Float], state: VadStreamState) throws -> VadStreamResult {
        frames.append(frame)
        inputStates.append(state.processedSamples)
        if failFirst {
            failFirst = false
            throw VoiceActivityDetectionError.invalidModelOutput
        }
        var next = state
        next.processedSamples += frame.count
        return VadStreamResult(state: next, event: nil, probability: 0.01)
    }
}

private actor VoiceActivityInferenceHold {
    private var resume: CheckedContinuation<Void, Never>?
    private var blocked = true

    func wait() async {
        guard blocked else { return }
        await withCheckedContinuation { resume = $0 }
    }

    func release() {
        blocked = false
        resume?.resume()
        resume = nil
    }
}

private func assertThrowsAsync<T>(
    _ operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
