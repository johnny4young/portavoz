import Foundation
import XCTest

@testable import portavoz_app

@MainActor
final class DictationSessionMeasurementTests: XCTestCase {
    func testRealControllerSeparatesPreparationAndDispatchWithoutCopyingContent() async throws {
        for text in ["Don't delete these notes", "No borres el café — 1.250,50 €", "Don’t delete C++"] {
            let harness = DictationControllerHarness(text: text)
            let clock = Clock()
            var dependencies = harness.dependencies
            dependencies.measurementClock = { clock.value }
            let load = dependencies.acquireRuntime
            dependencies.acquireRuntime = {
                clock.advance(4)
                return try await load()
            }
            let makeMicrophone = dependencies.makeMicrophone
            dependencies.makeMicrophone = {
                let microphone = makeMicrophone()
                return .init(source: microphone.source, warmUp: { await clock.advance(2) })
            }
            harness.controller.toggle(using: dependencies)
            await eventually { !harness.controller.partialText.isEmpty }
            XCTAssertTrue(harness.measurements.isEmpty)
            clock.advance(3)
            harness.now = harness.now.addingTimeInterval(1)
            harness.controller.toggle(using: dependencies)
            await eventually { harness.measurements.count == 1 }
            let receipt = try XCTUnwrap(harness.measurements.first)
            XCTAssertEqual(receipt.outcome, .dispatchReported)
            XCTAssertFalse(receipt.verifiedDeliveryMeasured)
            XCTAssertEqual(receipt.elapsedSeconds["runtimeReady"], 4)
            XCTAssertEqual(receipt.elapsedSeconds["microphoneReady"], 6)
            XCTAssertEqual(receipt.elapsedSeconds["firstBufferHandled"], 6)
            XCTAssertEqual(receipt.elapsedSeconds["firstCaptionHandled"], 6)
            XCTAssertEqual(receipt.elapsedSeconds["stopRequested"], 9)
            XCTAssertEqual(receipt.terminalSeconds, 9)
            XCTAssertEqual(Set(receipt.elapsedSeconds.keys), Set(DictationSessionMeasurement.Point.allCases.map(\.rawValue)))
            XCTAssertEqual(harness.insertions, [text])
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["schemaVersion", "elapsedSeconds", "terminalSeconds", "outcome", "verifiedDeliveryMeasured"])
            harness.controller.cancel()
            XCTAssertEqual(harness.measurements.count, 1, "Closing the confirmation is not another cancellation receipt")
        }
    }

    func testDeniedAndSubminimumRequestsCannotLookLikePreparedSessions() async throws {
        let denied = DictationControllerHarness(text: "Never read")
        var dependencies = denied.dependencies
        dependencies.canInsert = { false }
        denied.controller.toggle(using: dependencies)
        let rejected = try XCTUnwrap(denied.measurements.first)
        XCTAssertEqual(rejected.outcome, .permissionDenied)
        XCTAssertTrue(rejected.elapsedSeconds.isEmpty)
        XCTAssertEqual(denied.loads, 0)
        denied.controller.cancel()
        XCTAssertEqual(denied.measurements.count, 1)

        let short = DictationControllerHarness(text: "No.")
        short.controller.toggle(using: short.dependencies)
        await eventually { !short.controller.partialText.isEmpty }
        short.controller.toggle(using: short.dependencies)
        let cancelled = try XCTUnwrap(short.measurements.first)
        XCTAssertEqual(cancelled.outcome, .cancelled)
        XCTAssertNotNil(cancelled.elapsedSeconds["stopRequested"])
        XCTAssertNil(cancelled.elapsedSeconds["deliveryStarted"])
        XCTAssertTrue(short.insertions.isEmpty)
    }

    func testLatePreparationCannotAmendCancelledReceiptOrOwnRestart() async throws {
        let harness = DictationControllerHarness(text: "No private receipt text")
        let gate = Gate()
        var slow = harness.dependencies
        let retiredMicrophone = ControlledDictationMicrophone()
        slow.makeMicrophone = { .init(source: retiredMicrophone, warmUp: {}) }
        let load = slow.acquireRuntime
        slow.acquireRuntime = {
            await gate.wait()
            return try await load()
        }
        harness.controller.toggle(using: slow)
        await eventually { gate.started }
        harness.controller.cancel()
        let first = try XCTUnwrap(harness.measurements.first)
        XCTAssertEqual(first.outcome, .cancelled)
        XCTAssertTrue(first.elapsedSeconds.isEmpty)
        harness.controller.toggle(using: harness.dependencies)
        await eventually { !harness.controller.partialText.isEmpty }
        gate.release()
        await eventually { harness.finishes == 1 }
        XCTAssertEqual(harness.measurements, [first])
        harness.controller.cancel()
        XCTAssertEqual(harness.measurements.count, 2)
        XCTAssertEqual(harness.measurements[0], first)
        XCTAssertNotNil(harness.measurements[1].elapsedSeconds["firstCaptionHandled"])
    }

    func testCancelAndRestartBeforeTaskSchedulingKeepSeparateMeasurements() async throws {
        let first = DictationControllerHarness(text: "Not admitted")
        let second = DictationControllerHarness(text: "A different session")
        // Deliberately no suspension between start, cancel and restart. The
        // first task has not entered runSession when the recorder is replaced.
        first.controller.toggle(using: first.dependencies)
        first.controller.cancel()
        first.controller.toggle(using: second.dependencies)
        await eventually { !first.controller.partialText.isEmpty }
        first.controller.cancel()
        await eventually { first.finishes == 1 && second.finishes == 1 }
        XCTAssertEqual(first.measurements.count, 1)
        XCTAssertEqual(first.measurements.first?.elapsedSeconds, [:])
        XCTAssertEqual(second.measurements.count, 1)
        XCTAssertNotNil(second.measurements.first?.elapsedSeconds["firstCaptionHandled"])
        XCTAssertTrue(first.insertions.isEmpty)
        XCTAssertTrue(second.insertions.isEmpty)
    }

    func testCancelDuringDeliveryDoesNotClaimRollbackOrLaterSuccess() async throws {
        let harness = DictationControllerHarness(text: "Do not paste twice")
        let gate = Gate()
        var dependencies = harness.dependencies
        dependencies.insert = { _ in
            await gate.wait()
            return .inserted
        }
        harness.controller.toggle(using: dependencies)
        await eventually { !harness.controller.partialText.isEmpty }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
        await eventually { gate.started }
        harness.controller.cancel()
        let receipt = try XCTUnwrap(harness.measurements.first)
        XCTAssertEqual(receipt.outcome, .cancelled)
        XCTAssertNotNil(receipt.elapsedSeconds["deliveryStarted"], "Cancellation cannot promise to undo an already-entered inserter")
        XCTAssertNil(receipt.elapsedSeconds["deliveryReturned"])
        gate.release()
        await eventually { harness.finishes == 1 }
        XCTAssertEqual(harness.measurements, [receipt])
        XCTAssertEqual(harness.controller.phase, .idle)
    }

    func testEmptyFailedAndDisabledObservationsHaveDistinctOutcomes() async throws {
        for text in ["", "… — !!!", "No borres esto"] {
            let harness = DictationControllerHarness(text: text)
            var dependencies = harness.dependencies
            dependencies.insert = { _ in .focusUnavailable }
            harness.controller.toggle(using: dependencies)
            await eventually { harness.hints != nil }
            harness.now = harness.now.addingTimeInterval(1)
            harness.controller.toggle(using: dependencies)
            await eventually { harness.measurements.count == 1 }
            let receipt = try XCTUnwrap(harness.measurements.first)
            XCTAssertEqual(receipt.outcome, text == "No borres esto" ? .deliveryRejected : .empty)
            XCTAssertFalse(receipt.verifiedDeliveryMeasured)
            harness.controller.cancel()
        }
        let failed = DictationControllerHarness(text: "Unused")
        var failing = failed.dependencies
        failing.acquireRuntime = { throw Failure.synthetic }
        failed.controller.toggle(using: failing)
        await eventually { failed.measurements.count == 1 }
        XCTAssertEqual(failed.measurements.first?.outcome, .pipelineFailed)
        XCTAssertEqual(failed.measurements.first?.elapsedSeconds, [:])
        failed.controller.cancel()

        let unobserved = DictationControllerHarness(text: "Normal session")
        var disabled = unobserved.dependencies
        disabled.measurementSink = nil
        disabled.measurementClock = { XCTFail("An unobserved session must not read the measurement clock"); return .now }
        unobserved.controller.toggle(using: disabled)
        await eventually { !unobserved.controller.partialText.isEmpty }
        unobserved.controller.cancel()
        XCTAssertTrue(unobserved.measurements.isEmpty)
    }

    private func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Controller call site did not reach the expected state", file: file, line: line)
    }

    private enum Failure: Error { case synthetic }

    @MainActor
    private final class Clock {
        var value = ContinuousClock.now
        func advance(_ seconds: Int) { value = value.advanced(by: .seconds(seconds)) }
    }

    @MainActor
    private final class Gate {
        var started = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            started = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }
}
