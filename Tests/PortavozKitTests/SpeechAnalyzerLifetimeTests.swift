import XCTest
import PortavozCore

@testable import TranscriptionKit

#if canImport(Speech)
final class SpeechAnalyzerLifetimeTests: XCTestCase {
    func testAudioFeederRejectsInvalidMiddleChunkInsteadOfFinalizingAShorterTranscript() async {
        let evidence = SpeechAnalyzerFeedEvidence()
        let audio = AsyncStream<AudioChunk> { continuation in
            for sample in [1, 2, 3] {
                continuation.yield(AudioChunk(channel: .microphone,
                                              samples: [Float(sample)], sampleRate: 16_000,
                                              timestamp: Double(sample)))
            }
            continuation.finish()
        }
        let outcome = await SpeechAnalyzerAudioFeed.run(
            audio,
            convert: { chunk in
                chunk.samples.first == 2 ? nil : Int(chunk.samples[0])
            },
            yield: { evidence.yield($0) },
            finalize: { evidence.finalize() },
            abort: { evidence.abort() })

        XCTAssertEqual(outcome, .invalidInput)
        XCTAssertEqual(evidence.snapshot, .init(yielded: [1], finalized: false, aborted: true))
    }

    func testAudioFeederAcceptsEmptyControlChunkAndFinalizesCompleteInput() async {
        let evidence = SpeechAnalyzerFeedEvidence()
        let audio = AsyncStream<AudioChunk> { continuation in
            continuation.yield(AudioChunk(channel: .microphone,
                                          samples: [], sampleRate: 16_000, timestamp: 0))
            continuation.yield(AudioChunk(channel: .microphone,
                                          samples: [1], sampleRate: 16_000, timestamp: 1))
            continuation.finish()
        }
        let outcome = await SpeechAnalyzerAudioFeed.run(
            audio,
            convert: { Int($0.samples[0]) },
            yield: { evidence.yield($0) },
            finalize: { evidence.finalize() },
            abort: { evidence.abort() })

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(evidence.snapshot, .init(yielded: [1], finalized: true, aborted: false))
    }

    func testConcurrentCancellationCallersAwaitOneCompletedOperation() async {
        let operation = ControlledSpeechAnalyzerCancellation()
        let gate = SpeechAnalyzerCancellationGate {
            await operation.run()
        }

        let first = Task { await gate.cancel() }
        await operation.waitUntilStarted()
        let secondStarted = AsyncFlag()
        let secondCompleted = AsyncFlag()
        let second = Task {
            await secondStarted.set()
            await gate.cancel()
            await secondCompleted.set()
        }

        await secondStarted.waitUntilSet()
        try? await Task.sleep(for: .milliseconds(20))
        let completedBeforeRelease = await secondCompleted.value
        XCTAssertFalse(
            completedBeforeRelease,
            "a coalesced caller must await the in-flight analyzer cancellation")

        await operation.release()
        await first.value
        await second.value
        await gate.cancel()

        let invocationCount = await operation.invocationCount
        XCTAssertEqual(invocationCount, 1)
    }

    func testConsumerCompletionCancelsAndDrainsTheFeederBeforeReturning() async throws {
        let feeder = BlockingSpeechAnalyzerFeeder()

        let inputFinished = try await SpeechAnalyzerFeedScope.run(
            feeder: { await feeder.run() },
            consuming: { await feeder.waitUntilStarted() })

        XCTAssertEqual(inputFinished, false)
        let wasCancelled = await feeder.wasCancelled
        XCTAssertTrue(
            wasCancelled,
            "an early result-stream completion must not leave the input feeder alive")
    }

    func testConsumerFailureCancelsAndDrainsTheFeederBeforeEscaping() async {
        let feeder = BlockingSpeechAnalyzerFeeder()

        do {
            _ = try await SpeechAnalyzerFeedScope.run(
                feeder: { await feeder.run() },
                consuming: {
                    await feeder.waitUntilStarted()
                    throw SpeechAnalyzerFeedTestError.consumerFailed
                })
            XCTFail("expected the consumer failure")
        } catch {
            XCTAssertEqual(
                error as? SpeechAnalyzerFeedTestError,
                .consumerFailed)
        }

        let wasCancelled = await feeder.wasCancelled
        XCTAssertTrue(
            wasCancelled,
            "the error must not escape while the feeder still owns live input")
    }

    func testParentCancellationCancelsAndDrainsTheFeeder() async {
        let feeder = BlockingSpeechAnalyzerFeeder()
        let operation = Task {
            try await SpeechAnalyzerFeedScope.run(
                feeder: { await feeder.run() },
                consuming: {
                    await feeder.waitUntilStarted()
                    try await Task.sleep(for: .seconds(30))
                })
        }

        await feeder.waitUntilStarted()
        operation.cancel()

        do {
            _ = try await operation.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let wasCancelled = await feeder.wasCancelled
        XCTAssertTrue(
            wasCancelled,
            "the cancelled parent must not leave an unstructured feeder behind")
    }
}

private final class SpeechAnalyzerFeedEvidence: @unchecked Sendable {
    struct Snapshot: Equatable {
        var yielded: [Int] = []
        var finalized = false
        var aborted = false
    }

    private let lock = NSLock()
    private var value = Snapshot()

    var snapshot: Snapshot { lock.withLock { value } }
    func yield(_ value: Int) { lock.withLock { self.value.yielded.append(value) } }
    func finalize() { lock.withLock { value.finalized = true } }
    func abort() { lock.withLock { value.aborted = true } }
}

private enum SpeechAnalyzerFeedTestError: Error, Equatable {
    case consumerFailed
}

private actor ControlledSpeechAnalyzerCancellation {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var invocationCount = 0

    func run() async {
        invocationCount += 1
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor AsyncFlag {
    private(set) var value = false

    func set() {
        value = true
    }

    func waitUntilSet() async {
        while !value {
            await Task.yield()
        }
    }
}

private actor BlockingSpeechAnalyzerFeeder {
    private var started = false
    private(set) var wasCancelled = false

    func run() async -> Bool {
        started = true
        do {
            try await Task.sleep(for: .seconds(30))
            return true
        } catch {
            wasCancelled = Task.isCancelled || error is CancellationError
            return false
        }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }
}
#endif
