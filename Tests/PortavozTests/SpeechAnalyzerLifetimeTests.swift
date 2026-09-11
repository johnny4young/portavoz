import XCTest

@testable import TranscriptionKit

#if canImport(Speech)
final class SpeechAnalyzerLifetimeTests: XCTestCase {
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
