import PortavozCore
import XCTest

@testable import portavoz_app

final class FirstListenControllerTests: XCTestCase {
    @MainActor
    func testColdCaptionPreparationCompletesBeforeTheMicrophoneStarts() async {
        let capture = ControlledFirstListenCapture()
        let captions = ControlledFirstListenCaptionPreparation()
        let controller = FirstListenController(
            captureFactory: { await capture.session() },
            captionFactory: { _ in await captions.prepare() })

        controller.start()
        let preparationStarted = await captions.waitUntilStarted()
        XCTAssertTrue(preparationStarted)
        let sessionsBeforeReadiness = await capture.sessionCount
        XCTAssertEqual(
            sessionsBeforeReadiness,
            0,
            "cold SpeechAnalyzer preparation must not accumulate microphone buffers")

        await captions.release()
        let reachedListening = await waitForPhase(.listening, in: controller)
        XCTAssertTrue(reachedListening)
        let sessionsAfterReadiness = await capture.sessionCount
        XCTAssertEqual(sessionsAfterReadiness, 1)

        controller.cancel()
        let stopped = await capture.waitForStopCount(1)
        XCTAssertTrue(stopped)
    }

    @MainActor
    func testCancellationDuringCaptionPreparationNeverStartsTheMicrophone() async {
        let capture = ControlledFirstListenCapture()
        let captions = ControlledFirstListenCaptionPreparation()
        let controller = FirstListenController(
            captureFactory: { await capture.session() },
            captionFactory: { _ in await captions.prepare() })

        controller.start()
        let preparationStarted = await captions.waitUntilStarted()
        XCTAssertTrue(preparationStarted)
        controller.cancel()
        await captions.release()

        try? await Task.sleep(for: .milliseconds(20))
        let sessionCount = await capture.sessionCount
        XCTAssertEqual(sessionCount, 0)
        XCTAssertEqual(controller.phase, .idle)
    }

    @MainActor
    func testCancellationStopsCaptureAndCannotPublishACompletedPhase() async {
        let capture = ControlledFirstListenCapture()
        let controller = FirstListenController(
            captureFactory: { await capture.session() },
            captionFactory: { _ in nil })

        controller.start()
        let reachedListening = await waitForPhase(.listening, in: controller)
        XCTAssertTrue(reachedListening)
        await capture.yield(
            AudioChunk(
                channel: .microphone,
                samples: [0.25, -0.25],
                sampleRate: 16_000,
                timestamp: 0))
        let capturedPartialSample = await waitForSamples(in: controller)
        XCTAssertTrue(capturedPartialSample)

        controller.cancel()

        let stopped = await capture.waitForStopCount(1)
        XCTAssertTrue(stopped)
        XCTAssertEqual(controller.phase, .idle)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(
            controller.phase,
            .idle,
            "a cancelled run must not publish done after its cleanup finishes")
        XCTAssertTrue(
            controller.capturedSamples.isEmpty,
            "leaving an active listen must not offer an aborted sample for enrollment")
    }

    @MainActor
    func testNaturalInputCompletionStopsCaptureBeforePublishingTheResult() async {
        let capture = ControlledFirstListenCapture()
        let controller = FirstListenController(
            captureFactory: { await capture.session() },
            captionFactory: { _ in nil })

        controller.start()
        let reachedListening = await waitForPhase(.listening, in: controller)
        XCTAssertTrue(reachedListening)
        await capture.finishInput()

        let completed = await waitForPhase(.captionsUnavailable, in: controller)
        XCTAssertTrue(completed)
        let stopCount = await capture.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    @MainActor
    func testNaturalCompletionWithCaptionCapabilityPublishesDone() async {
        let capture = ControlledFirstListenCapture()
        let controller = FirstListenController(
            captureFactory: { await capture.session() },
            captionFactory: { _ in
                FirstListenCaptionFeed(
                    feed: { _ in },
                    finish: {},
                    cancel: {},
                    wait: {})
            })

        controller.start()
        let reachedListening = await waitForPhase(.listening, in: controller)
        XCTAssertTrue(reachedListening)
        await capture.finishInput()

        let completed = await waitForPhase(.done, in: controller)
        XCTAssertTrue(completed)
    }

    @MainActor
    func testCancellationWhileAwaitingCaptionsCancelsThemWithoutStoppingCaptureTwice() async {
        let capture = ControlledFirstListenCapture()
        let captions = ControlledFirstListenCaptionCompletion()
        let controller = FirstListenController(
            captureFactory: { await capture.session() },
            captionFactory: { _ in await captions.feed() })

        controller.start()
        let reachedListening = await waitForPhase(.listening, in: controller)
        XCTAssertTrue(reachedListening)
        await capture.finishInput()
        let captionWaitStarted = await captions.waitUntilWaiting()
        XCTAssertTrue(captionWaitStarted)
        let stoppedBeforeCancellation = await capture.waitForStopCount(1)
        XCTAssertTrue(stoppedBeforeCancellation)

        controller.cancel()

        let captionWasCancelled = await captions.waitForCancelCount(1)
        XCTAssertTrue(captionWasCancelled)
        try? await Task.sleep(for: .milliseconds(20))
        let stopCount = await capture.stopCount
        let cancelCount = await captions.cancelCount
        XCTAssertEqual(stopCount, 1, "each capture session must have exactly one teardown")
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(controller.phase, .idle)
    }

    @MainActor
    func testCancellationErrorFromCapturePreparationReturnsToIdle() async {
        let controller = FirstListenController(
            captureFactory: { throw CancellationError() },
            captionFactory: { _ in nil })

        controller.start()

        let returnedToIdle = await waitForPhase(.idle, in: controller)
        XCTAssertTrue(returnedToIdle)
    }

    @MainActor
    func testCancellingAfterCompletionPreservesTheReusableSample() async {
        let capture = ControlledFirstListenCapture()
        let controller = FirstListenController(
            captureFactory: { await capture.session() },
            captionFactory: { _ in nil })

        controller.start()
        let reachedListening = await waitForPhase(.listening, in: controller)
        XCTAssertTrue(reachedListening)
        await capture.yield(
            AudioChunk(
                channel: .microphone,
                samples: [0.25, -0.25],
                sampleRate: 16_000,
                timestamp: 0))
        await capture.finishInput()

        let completed = await waitForPhase(.captionsUnavailable, in: controller)
        XCTAssertTrue(completed)
        controller.cancel()

        XCTAssertEqual(controller.capturedSamples, [0.25, -0.25])
    }

    @MainActor
    private func waitForPhase(
        _ expected: FirstListenController.Phase,
        in controller: FirstListenController
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while controller.phase != expected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return controller.phase == expected
    }

    @MainActor
    private func waitForSamples(in controller: FirstListenController) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while controller.capturedSamples.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return !controller.capturedSamples.isEmpty
    }
}

private actor ControlledFirstListenCapture {
    private let stream: AsyncThrowingStream<AudioChunk, Error>
    private let continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    private(set) var sessionCount = 0
    private(set) var stopCount = 0

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream(of: AudioChunk.self)
    }

    func session() -> FirstListenAudioCapture {
        sessionCount += 1
        return FirstListenAudioCapture(
            chunks: stream,
            stop: { await self.stop() })
    }

    func finishInput() {
        continuation.finish()
    }

    func yield(_ chunk: AudioChunk) {
        continuation.yield(chunk)
    }

    func waitForStopCount(_ expected: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while stopCount < expected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return stopCount >= expected
    }

    private func stop() {
        stopCount += 1
        continuation.finish()
    }
}

private actor ControlledFirstListenCaptionPreparation {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func prepare() async -> FirstListenCaptionFeed? {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return nil
    }

    func waitUntilStarted() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !started, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return started
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ControlledFirstListenCaptionCompletion {
    private var waiting = false
    private var waitContinuation: CheckedContinuation<Void, Never>?
    private(set) var cancelCount = 0

    func feed() -> FirstListenCaptionFeed {
        FirstListenCaptionFeed(
            feed: { _ in },
            finish: {},
            cancel: { Task { await self.cancel() } },
            wait: { await self.wait() })
    }

    func waitUntilWaiting() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !waiting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return waiting
    }

    func waitForCancelCount(_ expected: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while cancelCount < expected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return cancelCount >= expected
    }

    private func cancel() {
        cancelCount += 1
        waitContinuation?.resume()
        waitContinuation = nil
    }

    private func wait() async {
        waiting = true
        await withCheckedContinuation { waitContinuation = $0 }
    }
}
