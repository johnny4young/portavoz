import Foundation
import PortavozCore
import TranscriptionKit
import XCTest
@testable import portavoz_app

@MainActor
extension DictationControllerTests {
    func testSourceEOFFixtureIsConsumedByCaptureNotDependencyConstruction() async throws {
        for language in [[], ["-seed-dictation-english"]] {
            let fixture = try XCTUnwrap(DictationUITestFixture(
                arguments: ["-seed-dictation", "-seed-dictation-source-eof"] + language,
                usesTemporaryStore: true))
            let controller = DictationController(presentsPanel: false)
            defer { controller.cancel() }
            _ = DictationUITestFixture.dependencies(fixture: fixture, beginCapture: { {} })
            controller.toggle(using: DictationUITestFixture.dependencies(fixture: fixture, beginCapture: { {} }))
            let failed = await awaitEventually {
                if case .failed = controller.phase { return true }
                return false
            }
            XCTAssertTrue(failed)
            XCTAssertEqual(controller.phase, .failed(DictationMicrophoneReadiness.Failure.interrupted.message))
            XCTAssertEqual(controller.confirmedText, fixture.text)
            controller.cancel()
            controller.toggle(using: DictationUITestFixture.dependencies(fixture: fixture, beginCapture: { {} }))
            let restarted = await awaitEventually { controller.partialText == fixture.text }
            XCTAssertTrue(restarted)
            XCTAssertEqual(controller.phase, .listening)
        }
    }

    func testOldSuccessCannotDismissNewSuccessWithTheSameWordCount() async {
        for texts in [["No borres estas notas.", "Don’t delete these notes."],
                      ["Don’t delete these notes.", "No borres estas notas."]] {
            let controller = DictationController(presentsPanel: false)
            let first = DictationControllerHarness(text: texts[0], controller: controller)
            let second = DictationControllerHarness(text: texts[1], controller: controller)
            let oldDeadline = FeedbackDeadline()
            let newDeadline = FeedbackDeadline()
            defer {
                controller.cancel()
                oldDeadline.release()
                newDeadline.release()
            }
            await finish(first, waitingOn: oldDeadline)
            await finish(second, waitingOn: newDeadline)
            oldDeadline.release()
            let oldFinished = await awaitEventually { oldDeadline.finished }
            XCTAssertTrue(oldFinished)
            XCTAssertEqual(controller.phase, .verified(4),
                           "A late deadline belongs to its completed session, not this equal phase")
            XCTAssertEqual(second.insertions, [texts[1]])
            newDeadline.release()
            let closed = await awaitEventually { controller.phase == .idle }
            XCTAssertTrue(closed)
        }
    }

    func testSuccessfulSessionReleasesRuntimeBeforeFeedbackDeadline() async {
        let harness = DictationControllerHarness(text: "Café C++ isn’t empty.")
        let deadline = FeedbackDeadline()
        defer {
            harness.controller.cancel()
            deadline.release()
        }
        await finish(harness, waitingOn: deadline)
        let released = await awaitEventually { harness.finishes == 1 }
        XCTAssertTrue(released, "A cosmetic confirmation must not retain a live model lease")
        XCTAssertEqual(harness.controller.phase, .verified(4))
        harness.controller.cancel()
        deadline.release()
        let finished = await awaitEventually { deadline.finished }
        XCTAssertTrue(finished)
        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertEqual(harness.finishes, 1)
    }

    func testLateFailureDeadlineCannotCloseAnotherFailureAfterCancel() async {
        let harness = DictationControllerHarness(text: "")
        let oldDeadline = FeedbackDeadline()
        let newDeadline = FeedbackDeadline()
        defer {
            harness.controller.cancel()
            oldDeadline.release()
            newDeadline.release()
        }
        var dependencies = harness.dependencies
        dependencies.canInsert = { false }
        dependencies.waitForFeedbackDismissal = { await oldDeadline.wait($0) }
        harness.controller.toggle(using: dependencies)
        let oldStarted = await awaitEventually { oldDeadline.started }
        XCTAssertTrue(oldStarted)
        XCTAssertEqual(oldDeadline.duration, .seconds(6))
        harness.controller.cancel()
        dependencies.waitForFeedbackDismissal = { await newDeadline.wait($0) }
        harness.controller.toggle(using: dependencies)
        let newStarted = await awaitEventually { newDeadline.started }
        XCTAssertTrue(newStarted)
        let currentFailure = harness.controller.phase
        guard case .failed = currentFailure else { return XCTFail("Expected a recoverable denial") }
        oldDeadline.release()
        let oldFinished = await awaitEventually { oldDeadline.finished }
        XCTAssertTrue(oldFinished)
        XCTAssertEqual(harness.controller.phase, currentFailure)
        XCTAssertEqual(harness.loads, 0)
        XCTAssertTrue(harness.insertions.isEmpty)
        newDeadline.release()
        let closed = await awaitEventually { harness.controller.phase == .idle }
        XCTAssertTrue(closed)
    }

    func testLateSuccessDeadlineCannotDismissPermissionFailureOrRestartedCapture() async {
        for deny in [false, true] {
            let controller = DictationController(presentsPanel: false)
            let first = DictationControllerHarness(text: "No borres estas notas.", controller: controller)
            let next = DictationControllerHarness(text: "Don’t delete these notes.", controller: controller)
            let oldDeadline = FeedbackDeadline()
            let nextDeadline = FeedbackDeadline()
            defer {
                controller.cancel()
                oldDeadline.release()
                nextDeadline.release()
            }
            await finish(first, waitingOn: oldDeadline)
            var dependencies = next.dependencies
            dependencies.canInsert = { !deny }
            dependencies.waitForFeedbackDismissal = { await nextDeadline.wait($0) }
            controller.toggle(using: dependencies)
            let ready = await awaitEventually {
                deny ? nextDeadline.started : controller.partialText == next.text
            }
            XCTAssertTrue(ready)
            let newPhase = controller.phase
            oldDeadline.release()
            let oldFinished = await awaitEventually { oldDeadline.finished }
            XCTAssertTrue(oldFinished)
            XCTAssertEqual(controller.phase, newPhase)
            XCTAssertTrue(next.insertions.isEmpty)
        }
    }

    func testSourceCompletionWithoutStopNeverAuthorizesDelivery() async {
        for text in ["No borres estas notas.", "Don’t delete these notes.", "… — !!!", ""] {
            for elapsed in [0.1, 0.75, 1.0] {
                let harness = DictationControllerHarness(text: text)
                harness.controller.toggle(using: harness.dependencies)
                let ready = await awaitEventually { harness.hints != nil }
                XCTAssertTrue(ready)
                harness.now = harness.now.addingTimeInterval(elapsed)
                // A device or source may complete without throwing. This is
                // not the user's Stop gesture and must never authorize paste.
                await harness.microphone.stop()
                let finished = await awaitEventually { harness.finishes == 1 }
                XCTAssertTrue(finished)
                XCTAssertTrue(harness.insertions.isEmpty,
                              "Unrequested EOF pasted text after \(elapsed) seconds")
                assertInterrupted(harness)
                harness.controller.cancel()
            }
        }
    }

    func testCancelledStreamCompletionCannotWriteIntoANewPreparingSession() async {
        for text in ["No borres estas notas.", "Don’t delete these notes."] {
            let controller = DictationController(presentsPanel: false)
            let old = DictationControllerHarness(text: text, controller: controller)
            let next = DictationControllerHarness(text: "New text must own the panel.", controller: controller)
            let gate = PreparationGate()
            defer { controller.cancel(); gate.release() }
            controller.toggle(using: old.dependencies)
            let readOld = await awaitEventually { controller.partialText == text }
            XCTAssertTrue(readOld)
            controller.cancel()
            var dependencies = next.dependencies
            let acquire = dependencies.acquireRuntime
            dependencies.acquireRuntime = { await gate.wait(); return try await acquire() }
            controller.toggle(using: dependencies)
            let drained = await awaitEventually { gate.started && old.finishes == 1 }
            XCTAssertTrue(drained)
            XCTAssertEqual(controller.phase, .preparing)
            XCTAssertEqual(controller.confirmedText, "")
            XCTAssertEqual(controller.partialText, "")
            XCTAssertTrue(old.insertions.isEmpty)
            XCTAssertTrue(next.insertions.isEmpty)
        }
    }

    func testRecognizerCompletionWithoutStopDoesNotWaitForLiveMicrophoneOrInsert() async {
        let harness = DictationControllerHarness(text: "Don’t discard the microphone boundary.")
        defer { harness.controller.cancel() }
        harness.controller.toggle(using: harness.dependencies)
        let ready = await awaitEventually { harness.controller.partialText == harness.text }
        XCTAssertTrue(ready)
        harness.transcriptOutput?.finish()
        let closed = await awaitEventually { harness.finishes == 1 }
        XCTAssertTrue(closed, "Unexpected recognizer completion must stop, not join, a live microphone pump")
        XCTAssertTrue(harness.insertions.isEmpty)
        assertInterrupted(harness)
    }

    func testCancelledPreparationDoesNotMasqueradeAsUserCancellationAndCanRestart() async {
        for text in ["No borres estas notas.", "Don’t delete these notes."] {
            let harness = DictationControllerHarness(text: text)
            defer { harness.controller.cancel() }
            var dependencies = harness.dependencies
            dependencies.acquireRuntime = { throw CancellationError() }
            harness.controller.toggle(using: dependencies)
            let failed = await awaitEventually {
                if case .failed = harness.controller.phase { return true }
                return false
            }
            XCTAssertTrue(failed, "A dependency abort must not leave an uncancelled owner listening forever")
            let starts = await harness.microphone.starts
            XCTAssertEqual(starts, 0)
            XCTAssertTrue(harness.insertions.isEmpty)
            // The menu must start a new attempt from failure without first
            // interpreting its action as Stop for the already-ended session.
            harness.controller.toggle(using: harness.dependencies)
            let restarted = await awaitEventually { harness.controller.partialText == text }
            XCTAssertTrue(restarted)
            XCTAssertEqual(harness.controller.phase, .listening)
        }
    }

    func testUnexpectedCompletionStaysVisibleUntilDismissed() async {
        for text in ["No borres estas notas.", "Don’t delete these notes."] {
            let harness = DictationControllerHarness(text: text)
            defer { harness.controller.cancel() }
            var dismissalWaits = 0
            var dependencies = harness.dependencies
            dependencies.waitForFeedbackDismissal = { _ in dismissalWaits += 1 }
            harness.controller.toggle(using: dependencies)
            let ready = await awaitEventually { harness.controller.partialText == text }
            XCTAssertTrue(ready)
            harness.transcriptOutput?.finish(throwing: CancellationError())
            let failed = await awaitEventually {
                if case .failed = harness.controller.phase { return true }
                return false
            }
            XCTAssertTrue(failed)
            // An immediate dismissal wait would close the panel on the next turn.
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(dismissalWaits, 0, "Nothing was typed; the failure must wait for the user")
            XCTAssertEqual(harness.controller.phase, .failed(
                LiveSpeechFailureMessage.dictation(DictationSessionError.unexpectedCompletion)))
        }
    }

    func testCancelledRecognizerFailsWithoutDeliveryEvenAfterAnAcceptedStop() async {
        for text in ["No borres estas notas.", "Don’t delete these notes."] {
            for acceptedStop in [false, true] {
                let harness = DictationControllerHarness(text: text)
                defer { harness.controller.cancel() }
                harness.controller.toggle(using: harness.dependencies)
                let ready = await awaitEventually { harness.controller.partialText == text }
                XCTAssertTrue(ready)
                if acceptedStop {
                    harness.now = harness.now.addingTimeInterval(1)
                    harness.controller.toggle(using: harness.dependencies)
                }
                // The engine's cancellation is not cancellation of the
                // controller task, and cannot authorize partial delivery.
                harness.transcriptOutput?.finish(throwing: CancellationError())
                let failed = await awaitEventually {
                    if case .failed = harness.controller.phase { return true }
                    return false
                }
                XCTAssertTrue(failed)
                XCTAssertEqual(harness.controller.phase, .failed(
                    LiveSpeechFailureMessage.dictation(DictationSessionError.unexpectedCompletion)))
                XCTAssertEqual(harness.measurements.map(\.outcome), [.pipelineFailed])
                XCTAssertEqual(harness.finishes, 1)
                XCTAssertEqual(harness.controller.partialText, text)
                XCTAssertTrue(harness.insertions.isEmpty)
            }
        }
    }

    func testAcceptedStopIsExactlyOnceAndCannotAuthorizeTheNextSession() async {
        let controller = DictationController(presentsPanel: false)
        let first = DictationControllerHarness(text: "No borres estas notas.", controller: controller)
        let second = DictationControllerHarness(text: "Don’t delete these notes.", controller: controller)
        let receiver = TextReadbackHarness()
        defer { controller.cancel(); receiver.board.releaseGlobally() }
        let firstDependencies = first.verifyingDelivery(using: receiver)
        controller.toggle(using: firstDependencies)
        let ready = await awaitEventually { controller.partialText == first.text }
        XCTAssertTrue(ready)
        first.now = first.now.addingTimeInterval(0.75)
        for _ in 0..<3 { controller.toggle(using: firstDependencies) }
        let delivered = await awaitEventually { first.finishes == 1 }
        XCTAssertTrue(delivered)
        XCTAssertEqual(first.insertions, [first.text])
        controller.toggle(using: second.dependencies)
        let secondReady = await awaitEventually { controller.partialText == second.text }
        XCTAssertTrue(secondReady)
        second.now = second.now.addingTimeInterval(1)
        await second.microphone.stop()
        let secondClosed = await awaitEventually { second.finishes == 1 }
        XCTAssertTrue(secondClosed)
        XCTAssertTrue(second.insertions.isEmpty, "A previous accepted Stop is not authorization for this owner")
        if case .failed = controller.phase {} else { XCTFail("Expected an unrequested EOF failure") }
    }

    func testMissingHotkeyReleaseCanBeRecoveredByNextPress() async {
        for text in ["No borres estas notas.", "Don’t delete these notes."] {
            let harness = DictationControllerHarness(text: text)
            defer { harness.controller.cancel() }
            let firstPress = harness.now
            harness.controller.handleHotkeyPress(using: harness.dependencies, at: firstPress)
            let ready = await awaitEventually { harness.controller.partialText == text }
            XCTAssertTrue(ready)
            harness.now = firstPress.addingTimeInterval(1)
            harness.controller.handleHotkeyPress(using: harness.dependencies, at: harness.now)
            harness.controller.handleHotkeyRelease(at: harness.now.addingTimeInterval(1))
            let delivered = await awaitEventually { harness.insertions == [text] }
            XCTAssertTrue(delivered, "A lost first key-up must not strand the capture")
            XCTAssertEqual(harness.insertions, [text], "The late release cannot repeat delivery")
        }
    }

    func testLateHotkeyReleaseCannotStopANewerMenuStartedSession() async {
        for text in ["No borres estas notas.", "Don’t delete these notes."] {
            let controller = DictationController(presentsPanel: false)
            let first = DictationControllerHarness(text: text, controller: controller)
            let next = DictationControllerHarness(text: "Keep this new session open.", controller: controller)
            defer { controller.cancel() }
            let firstPress = first.now
            controller.handleHotkeyPress(using: first.dependencies, at: firstPress)
            let ready = await awaitEventually { controller.partialText == text }
            XCTAssertTrue(ready)
            controller.cancel()
            controller.toggle(using: next.dependencies)
            let restarted = await awaitEventually { controller.partialText == next.text }
            XCTAssertTrue(restarted)
            controller.handleHotkeyRelease(at: firstPress.addingTimeInterval(2))
            XCTAssertEqual(controller.phase, .listening)
            XCTAssertTrue(next.insertions.isEmpty, "The prior key-up cannot authorize this session's Stop")
        }
    }

    func testCancelRevokesPendingStopBeforeRestartAndEarlyStopRemainsCancellation() async {
        for elapsed in [0.0, 0.749, 0.75, 1.0] {
            let controller = DictationController(presentsPanel: false)
            let first = DictationControllerHarness(text: "No borres estas notas.", controller: controller)
            let second = DictationControllerHarness(text: "Don’t delete these notes.", controller: controller)
            defer { controller.cancel() }
            controller.toggle(using: first.dependencies)
            let ready = await awaitEventually { controller.partialText == first.text }
            XCTAssertTrue(ready)
            first.now = first.now.addingTimeInterval(elapsed)
            controller.toggle(using: first.dependencies)
            if elapsed < 0.75 { XCTAssertEqual(controller.phase, .idle) }
            controller.cancel()
            controller.toggle(using: second.dependencies)
            let nextReady = await awaitEventually { controller.partialText == second.text }
            XCTAssertTrue(nextReady)
            await second.microphone.stop()
            let drained = await awaitEventually { first.finishes == 1 && second.finishes == 1 }
            XCTAssertTrue(drained)
            XCTAssertTrue(first.insertions.isEmpty)
            XCTAssertTrue(second.insertions.isEmpty)
            if case .failed = controller.phase {} else { XCTFail("Only the new EOF failure may own the panel") }
        }
    }

    func testNativeStopMustReturnBeforeDeliveryOrRuntimeRelease() async {
        for text in ["No borres estas notas.", "Don’t delete these notes."] {
            for cancelWhileStopping in [false, true] {
                let harness = DictationControllerHarness(text: text)
                let drain = NativeStopGate()
                let prematureDelivery = expectation(description: "No delivery before native Stop returns")
                prematureDelivery.isInverted = true
                await harness.microphone.holdStop { await drain.wait() }
                var dependencies = harness.dependencies
                let capture = dependencies.captureDestination
                dependencies.captureDestination = {
                    let destination = capture()
                    return CapturedDictationDestination(name: destination.name, canRetry: destination.canRetry) { value in
                        if !drain.released { prematureDelivery.fulfill() }
                        return await destination.insert(value)
                    }
                }
                harness.controller.toggle(using: dependencies)
                let ready = await awaitEventually { harness.controller.partialText == text }
                XCTAssertTrue(ready)
                harness.now = harness.now.addingTimeInterval(1)
                harness.controller.toggle(using: dependencies)
                let stopping = await awaitEventually { drain.started }
                XCTAssertTrue(stopping)
                if cancelWhileStopping { harness.controller.cancel() }
                // Negative observation while the native boundary is explicitly
                // held; no fixed sleep is used to guess when Stop has finished.
                await fulfillment(of: [prematureDelivery], timeout: 0.1)
                XCTAssertEqual(harness.finishes, 0, "Stream EOF is not native teardown completion")
                XCTAssertTrue(harness.insertions.isEmpty)
                drain.release()
                let finished = await awaitEventually { harness.finishes == 1 }
                XCTAssertTrue(finished)
                XCTAssertEqual(harness.insertions, cancelWhileStopping ? [] : [text])
                harness.controller.cancel()
            }
        }
    }

    func testHeldHotkeyReleaseDuringPermissionPreparationCancelsWithoutAudio() async {
        for text in ["No borres estas notas.", "Don’t delete these notes."] {
            let harness = DictationControllerHarness(text: text)
            let permission = PreparationGate()
            defer { harness.controller.cancel(); permission.release() }
            var captureFinishes = 0
            var dependencies = harness.dependencies
            dependencies.beginCapture = { { captureFinishes += 1 } }
            dependencies.authorizeMicrophone = { await permission.wait(); return true }
            harness.controller.handleHotkeyPress(using: dependencies, at: harness.now)
            let preparing = await awaitEventually { permission.started }
            XCTAssertTrue(preparing)
            XCTAssertEqual(harness.controller.phase, .preparing)
            harness.controller.handleHotkeyRelease(at: harness.now.addingTimeInterval(2))
            XCTAssertEqual(harness.controller.phase, .idle,
                           "Gesture time cannot grant audio time while permission is pending")
            permission.release()
            let drained = await awaitEventually { captureFinishes == 1 }
            XCTAssertTrue(drained)
            let starts = await harness.microphone.starts
            XCTAssertEqual(starts, 0)
            XCTAssertEqual(harness.loads, 0)
            XCTAssertTrue(harness.insertions.isEmpty)
        }
    }

    private func finish(_ harness: DictationControllerHarness, waitingOn deadline: FeedbackDeadline) async {
        let receiver = TextReadbackHarness()
        defer { receiver.board.releaseGlobally() }
        var dependencies = harness.verifyingDelivery(using: receiver)
        dependencies.waitForFeedbackDismissal = { await deadline.wait($0) }
        harness.controller.toggle(using: dependencies)
        let transcribed = await awaitEventually { harness.controller.partialText == harness.text }
        XCTAssertTrue(transcribed)
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
        let waiting = await awaitEventually { deadline.started }
        XCTAssertTrue(waiting)
        XCTAssertEqual(deadline.duration, .milliseconds(1600))
        XCTAssertEqual(harness.insertions, [harness.text])
        XCTAssertEqual(receiver.posts, 1)
        XCTAssertEqual(receiver.requestedSpans.count, 1, "Feedback tests need an actual observed edit")
    }

}

@MainActor
private final class NativeStopGate {
    private(set) var started = false
    private(set) var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private final class FeedbackDeadline {
    private(set) var started = false
    private(set) var finished = false
    private(set) var duration: Duration?
    private var continuation: CheckedContinuation<Void, Never>?

    // Deliberately ignores cancellation: ownership must also reject a late
    // completion from a dependency that cannot immediately abort its work.
    func wait(_ duration: Duration) async {
        self.duration = duration
        started = true
        await withCheckedContinuation { continuation = $0 }
        finished = true
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
