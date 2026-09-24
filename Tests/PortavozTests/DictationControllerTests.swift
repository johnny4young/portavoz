import AppKit
import AudioCaptureKit
import Foundation
import os
import PortavozCore
import TranscriptionKit
import XCTest

@testable import portavoz_app

@MainActor
final class DictationControllerTests: XCTestCase {
    func testInvalidNativeEventTargetDoesNotBorrowClipboardOrFallBackToSession() async {
        let board = NSPasteboard(name: .init("app.portavoz.dictation-test." + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString("Do not replace — no reemplazar", forType: .string)
        let originalCount = board.changeCount
        for processID: pid_t in [0, -1, .min] {
            let result = await TextInserter.insert(
                "Must never be delivered", pasteboard: board, eventTarget: .process(processID))
            XCTAssertEqual(result, .eventUnavailable)
            XCTAssertEqual(board.changeCount, originalCount)
            XCTAssertEqual(board.string(forType: .string), "Do not replace — no reemplazar")
        }
    }

    func testExitedProcessTargetFailsBeforeClipboardMutation() async throws {
        let board = NSPasteboard(name: .init("app.portavoz.dictation-test." + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let originalCount = board.changeCount
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        let target = TextInserter.EventTarget.process(exited.processIdentifier)
        XCTAssertFalse(target.isAvailable)
        let result = await TextInserter.insert("Must never be delivered", pasteboard: board, eventTarget: target)
        XCTAssertEqual(result, .eventUnavailable)
        XCTAssertEqual(board.changeCount, originalCount)
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    func testNativeFixtureRequiresTemporaryCompositionExplicitActionAndUUIDClipboard() async {
        let key = DictationNativeUITestFixture.environmentKey
        let name = DictationNativeUITestFixture.pasteboardPrefix + UUID().uuidString
        for temporary in [false, true] {
            for arguments in [[], ["-seed-dictation"], ["-seed-dictation-native"]] {
                for candidate in [nil, "", "NSGeneralPboard", "app.portavoz.dictation-test.invalid", name] {
                    let environment = candidate.map { [key: $0] } ?? [:]
                    let fixture = DictationNativeUITestFixture(
                        arguments: arguments, environment: environment, usesTemporaryStore: temporary)
                    let admitted = temporary && arguments == ["-seed-dictation-native"] && candidate == name
                    XCTAssertEqual(fixture != nil, admitted)
                    if let fixture {
                        XCTAssertEqual(fixture.status, "idle", "Construction must not arm native input")
                    }
                }
            }
        }
    }

    func testPermissionDenialDoesNotPrepareAudioOrModels() async {
        let harness = Harness(text: "No borres estas notas.")
        var dependencies = harness.dependencies
        dependencies.canInsert = { false }
        harness.controller.toggle(using: dependencies)
        guard case .failed = harness.controller.phase else {
            return XCTFail("permission denial must remain an actionable failure")
        }
        XCTAssertEqual(harness.loads, 0)
        let starts = await harness.microphone.starts
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(harness.insertions.isEmpty)
        harness.controller.cancel()
    }

    func testCancelAfterPartialNeverDeliversAndReleasesRuntime() async {
        for text in ["No borres estas notas.", "Don’t delete these notes."] {
            let harness = Harness(text: text)
            harness.controller.toggle(using: harness.dependencies)
            let reached1 = await awaitEventually { harness.controller.partialText == text }
            XCTAssertTrue(reached1)
            harness.controller.cancel()
            XCTAssertEqual(harness.controller.phase, .idle)
            let reached2 = await awaitEventually { harness.finishes == 1 }
            XCTAssertTrue(reached2)
            XCTAssertTrue(harness.insertions.isEmpty)
        }
    }

    func testMicrophoneErrorAfterPartialCannotBecomeSuccessfulInsertion() async {
        let errors: [any Error] = [SyntheticCaptureFailure.disconnected, CancellationError()]
        for text in ["No borres estas notas", "Don’t delete these notes"] {
            for error in errors {
                let harness = Harness(text: text)
                defer { harness.controller.cancel() }
                harness.controller.toggle(using: harness.dependencies)
                let partial = await awaitEventually { harness.controller.partialText == text }
                XCTAssertTrue(partial)
                await harness.microphone.fail(error)
                let finished = await awaitEventually { harness.finishes == 1 }
                XCTAssertTrue(finished, "A failed microphone must release its exact runtime")
                XCTAssertTrue(harness.insertions.isEmpty, "A partial after capture failure must not be pasted")
                guard case .failed = harness.controller.phase else {
                    XCTFail("Unexpected source cancellation is capture failure, not successful EOF")
                    continue
                }
            }
        }
    }

    func testCleanSourceEOFWithoutRequestedStopCannotDeliverPartial() async {
        for text in ["No borres estas notas", "Don’t delete these notes"] {
            let harness = Harness(text: text)
            defer { harness.controller.cancel() }
            harness.controller.toggle(using: harness.dependencies)
            let partial = await awaitEventually { harness.controller.partialText == text }
            XCTAssertTrue(partial)
            // A source can close normally without a user's Stop (for example,
            // a device teardown that never publishes a failure report).
            await harness.microphone.stop()
            let released = await awaitEventually { harness.finishes == 1 }
            XCTAssertTrue(released, "Unexpected EOF must release the runtime")
            XCTAssertTrue(harness.insertions.isEmpty, "EOF alone is not permission to paste")
            guard case .failed = harness.controller.phase else {
                XCTFail("Unexpected EOF after a partial must be an actionable failure")
                continue
            }
        }
    }

    func testCleanSourceEOFDuringStopTailCannotDeliverPartial() async {
        for text in ["No borres estas notas", "Don’t delete these notes"] {
            let harness = Harness(text: text)
            defer { harness.controller.cancel() }
            harness.controller.toggle(using: harness.dependencies)
            let partial = await awaitEventually { harness.controller.partialText == text }
            XCTAssertTrue(partial)
            harness.now = harness.now.addingTimeInterval(1)
            harness.controller.toggle(using: harness.dependencies)
            // Stop has been requested, but the controller has not yet issued
            // source.stop() after its 250 ms tail. This EOF is still untrusted.
            await harness.microphone.stop()
            let released = await awaitEventually { harness.finishes == 1 }
            XCTAssertTrue(released)
            XCTAssertTrue(harness.insertions.isEmpty, "The pending tail must not authorize early EOF")
            guard case .failed = harness.controller.phase else {
                XCTFail("Early EOF during Stop tail must remain an actionable failure")
                continue
            }
        }
    }

    func testProducerFailureSignalRetiresCaptureWithoutWaitingForBufferedEOF() async {
        for text in ["No borres estas notas", "Don’t delete these notes"] {
            for failure in [PortavozCore.CaptureFailure.overloaded, .sourceFailed] {
                let harness = Harness(text: text)
                defer { harness.controller.cancel() }
                harness.controller.toggle(using: harness.dependencies)
                let partial = await awaitEventually { harness.controller.partialText == text }
                XCTAssertTrue(partial)
                // The native source reports failure before its retained queue drains.
                // Do not finish this stream: retirement must not depend on future EOF.
                await harness.microphone.signalFailure(failure)
                let failed = await awaitEventually {
                    if case .failed = harness.controller.phase { return true }
                    return false
                }
                XCTAssertTrue(failed, "Producer failure must promptly leave the listening state")
                let released = await awaitEventually { harness.finishes == 1 }
                XCTAssertTrue(released, "Retire the source and release its runtime without a user Stop")
                XCTAssertTrue(harness.insertions.isEmpty)
            }
        }
    }

    func testRelayCapacityBoundaryNeverDeliversAfterDiscardingAudio() async {
        for text in ["No pagues 0,5 todavía", "Don’t pay 0.5 yet"] {
            for pendingChunks in [127, 128, 129] {
                let consumer = PreparationGate()
                let harness = Harness(text: text, consumerGate: consumer)
                defer {
                    consumer.release()
                    harness.controller.cancel()
                }
                harness.controller.toggle(using: harness.dependencies)
                let held = await awaitEventually {
                    consumer.started && harness.controller.partialText == text
                }
                XCTAssertTrue(held, "Hold the real relay consumer after the first partial")
                for index in 1...pendingChunks {
                    await harness.microphone.send(AudioChunk(
                        channel: .microphone, samples: [0.2 + Float(index) / 1_000],
                        sampleRate: 16_000, timestamp: Double(index) / 16_000))
                }
                let lastPeak = Float(0.2) + Float(pendingChunks) / 1_000
                let handled = await awaitEventually {
                    harness.controller.micLevel == lastPeak || harness.controller.phase != .listening
                }
                XCTAssertTrue(handled, "Observe pump progress before releasing the held consumer")
                harness.now = harness.now.addingTimeInterval(1)
                // Stop is valid; an input gap, not a short gesture, must veto delivery.
                if harness.controller.phase == .listening {
                    harness.controller.toggle(using: harness.dependencies)
                }
                consumer.release()
                let finished = await awaitEventually { harness.finishes == 1 }
                XCTAssertTrue(finished)
                if pendingChunks <= 128 {
                    XCTAssertEqual(harness.insertions, [text], "The exact capacity remains usable")
                } else {
                    XCTAssertTrue(harness.insertions.isEmpty, "Chunk 129 must not silently evict prior audio")
                    guard case .failed = harness.controller.phase else {
                        XCTFail("Overflow needs visible failure, not a successfully pasted suffix")
                        continue
                    }
                }
            }
        }
    }

    func testFinalProducerReportVetoesDeliveryEvenWithoutANotification() async {
        for text in ["No borres estas notas", "Don’t delete these notes"] {
            let harness = Harness(text: text)
            defer { harness.controller.cancel() }
            harness.controller.toggle(using: harness.dependencies)
            let partial = await awaitEventually { harness.controller.partialText == text }
            XCTAssertTrue(partial)
            await harness.microphone.finishWithUnnotifiedFailure()
            let finished = await awaitEventually { harness.finishes == 1 }
            XCTAssertTrue(finished)
            XCTAssertTrue(harness.insertions.isEmpty, "Inspect authoritative producer state before delivery")
            guard case .failed = harness.controller.phase else {
                XCTFail("A failed final report cannot become successful stream completion")
                continue
            }
        }
    }

    func testLateCaptureNotificationCannotClaimAnAlreadyDispatchedPasteWasPrevented() async {
        let harness = Harness(text: "Already dispatched — ya enviado")
        let delivery = PreparationGate()
        defer {
            delivery.release()
            harness.controller.cancel()
        }
        var dependencies = harness.dependencies
        let insert = dependencies.insert
        dependencies.insert = { text in
            let result = await insert(text)
            await delivery.wait()
            return result
        }
        harness.controller.toggle(using: dependencies)
        let partial = await awaitEventually { harness.controller.partialText == harness.text }
        XCTAssertTrue(partial)
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
        let dispatched = await awaitEventually { delivery.started }
        XCTAssertTrue(dispatched)
        XCTAssertEqual(harness.insertions, [harness.text])
        await harness.microphone.signalFailure(.sourceFailed)
        delivery.release()
        let finished = await awaitEventually { harness.finishes == 1 }
        XCTAssertTrue(finished)
        XCTAssertEqual(harness.insertions, [harness.text], "Do not repeat delivery")
        if case .failed = harness.controller.phase {
            XCTFail("A late notification cannot say nothing was inserted")
        }
    }

    func testFinalTextRunsThroughRealRulesAndSuppliesHintsToEngine() async {
        let harness = Harness(text: "eh Café C++")
        harness.set("es", forKey: DictationController.languageKey)
        harness.set("Kubernetes, Café", forKey: "customVocabulary")
        harness.set(
            #"[{"trigger":"C++","replacement":"Swift $5\\path"}]"#,
            forKey: DictationController.replacementsKey)
        harness.controller.toggle(using: harness.dependencies)
        let reached3 = await awaitEventually { !harness.controller.partialText.isEmpty }
        XCTAssertTrue(reached3)
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: harness.dependencies)
        let reached4 = await awaitEventually { !harness.insertions.isEmpty }
        XCTAssertTrue(reached4)
        XCTAssertEqual(harness.insertions, ["Café Swift $5\\path"])
        XCTAssertEqual(harness.hints?.language, "es")
        XCTAssertEqual(harness.hints?.vocabulary, ["Kubernetes", "Café"])
        harness.controller.cancel()
        let reached5 = await awaitEventually { harness.finishes == 1 }
        XCTAssertTrue(reached5)
    }

    func testPunctuationOnlyFinalDoesNotInvokeInsertion() async {
        let harness = Harness(text: "… — !!!")
        harness.controller.toggle(using: harness.dependencies)
        let reached6 = await awaitEventually { harness.hints != nil }
        XCTAssertTrue(reached6)
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: harness.dependencies)
        let reached7 = await awaitEventually { harness.finishes == 1 }
        XCTAssertTrue(reached7)
        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertTrue(harness.insertions.isEmpty)
    }

    func testCancelDuringModelPreparationCannotStartMicrophoneLater() async {
        let harness = Harness(text: "Late text must not appear")
        let gate = PreparationGate()
        var dependencies = harness.dependencies
        let load = dependencies.acquireRuntime
        dependencies.acquireRuntime = {
            await gate.wait()
            return try await load()
        }
        harness.controller.toggle(using: dependencies)
        let reached8 = await awaitEventually { gate.started }
        XCTAssertTrue(reached8)
        harness.controller.cancel()
        gate.release()
        let reached9 = await awaitEventually { harness.finishes == 1 }
        XCTAssertTrue(reached9)
        let starts = await harness.microphone.starts
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(harness.insertions.isEmpty)
        XCTAssertEqual(harness.controller.phase, .idle)
    }

    func testFixtureFlagsAreInertOutsideTemporaryComposition() async {
        for temporary in [false, true] {
            for arguments in [[], ["-seed-dictation"], ["-seed-dictation-unexpected-completion"],
                              ["-seed-dictation", "-seed-dictation-unexpected-completion"]] {
                XCTAssertEqual(
                    DictationUITestFixture(arguments: arguments, usesTemporaryStore: temporary) != nil,
                    temporary && arguments.contains("-seed-dictation"))
            }
        }
        XCTAssertFalse(DictationUITestFixture.dependencies(fixture: nil).canInsert())
        let failureArguments = ["-seed-dictation", "-seed-dictation-capture-failure"]
        XCTAssertNil(DictationUITestFixture(arguments: failureArguments, usesTemporaryStore: false))
        XCTAssertNil(DictationUITestFixture(
            arguments: ["-seed-dictation-capture-failure"], usesTemporaryStore: true))
        XCTAssertEqual(DictationUITestFixture(
            arguments: failureArguments, usesTemporaryStore: true)?.captureFailure, true)
        XCTAssertEqual(DictationUITestFixture(
            arguments: ["-seed-dictation"], usesTemporaryStore: true)?.captureFailure, false)
    }

    func testUnexpectedCompletionFixtureIsConsumedByCaptureNotDependencyConstruction() async throws {
        for language in [[], ["-seed-dictation-english"]] {
            let fixture = try XCTUnwrap(DictationUITestFixture(
                arguments: ["-seed-dictation", "-seed-dictation-unexpected-completion"] + language,
                usesTemporaryStore: true))
            let controller = DictationController(presentsPanel: false)
            defer { controller.cancel() }
            _ = DictationUITestFixture.dependencies(fixture: fixture)
            controller.toggle(using: DictationUITestFixture.dependencies(fixture: fixture))
            let failed = await awaitEventually {
                if case .failed = controller.phase { return true }
                return false
            }
            XCTAssertTrue(failed)
            XCTAssertEqual(controller.confirmedText, fixture.text)
            controller.cancel()
            controller.toggle(using: DictationUITestFixture.dependencies(fixture: fixture))
            let restarted = await awaitEventually { controller.partialText == fixture.text }
            XCTAssertTrue(restarted)
            XCTAssertEqual(controller.phase, .listening)
        }
    }

    func testOldSuccessCannotDismissNewSuccessWithTheSameWordCount() async {
        for texts in [["No borres estas notas.", "Don’t delete these notes."],
                      ["Don’t delete these notes.", "No borres estas notas."]] {
            let controller = DictationController(presentsPanel: false)
            let first = Harness(text: texts[0], controller: controller)
            let second = Harness(text: texts[1], controller: controller)
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
            XCTAssertEqual(controller.phase, .inserted(4),
                           "A late deadline belongs to its completed session, not this equal phase")
            XCTAssertEqual(second.insertions, [texts[1]])
            newDeadline.release()
            let closed = await awaitEventually { controller.phase == .idle }
            XCTAssertTrue(closed)
        }
    }

    func testSuccessfulSessionReleasesRuntimeBeforeFeedbackDeadline() async {
        let harness = Harness(text: "Café C++ isn’t empty.")
        let deadline = FeedbackDeadline()
        defer {
            harness.controller.cancel()
            deadline.release()
        }
        await finish(harness, waitingOn: deadline)
        let released = await awaitEventually { harness.finishes == 1 }
        XCTAssertTrue(released, "A cosmetic confirmation must not retain a live model lease")
        XCTAssertEqual(harness.controller.phase, .inserted(4))
        harness.controller.cancel()
        deadline.release()
        let finished = await awaitEventually { deadline.finished }
        XCTAssertTrue(finished)
        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertEqual(harness.finishes, 1)
    }

    func testLateFailureDeadlineCannotCloseAnotherFailureAfterCancel() async {
        let harness = Harness(text: "")
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
            let first = Harness(text: "No borres estas notas.", controller: controller)
            let next = Harness(text: "Don’t delete these notes.", controller: controller)
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
                let harness = Harness(text: text)
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
                if case .failed = harness.controller.phase {} else {
                    XCTFail("Unrequested EOF must expose a recoverable interruption, not success or idle")
                }
                harness.controller.cancel()
            }
        }
    }

    func testCancelledStreamCompletionCannotWriteIntoANewPreparingSession() async {
        for text in ["No borres estas notas.", "Don’t delete these notes."] {
            let controller = DictationController(presentsPanel: false)
            let old = Harness(text: text, controller: controller)
            let next = Harness(text: "New text must own the panel.", controller: controller)
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
            XCTAssertEqual(controller.phase, .listening)
            XCTAssertEqual(controller.confirmedText, "")
            XCTAssertEqual(controller.partialText, "")
            XCTAssertTrue(old.insertions.isEmpty)
            XCTAssertTrue(next.insertions.isEmpty)
        }
    }

    func testRecognizerCompletionWithoutStopDoesNotWaitForLiveMicrophoneOrInsert() async {
        let harness = Harness(text: "Don’t discard the microphone boundary.")
        defer { harness.controller.cancel() }
        harness.controller.toggle(using: harness.dependencies)
        let ready = await awaitEventually { harness.controller.partialText == harness.text }
        XCTAssertTrue(ready)
        harness.transcriptOutput?.finish()
        let closed = await awaitEventually { harness.finishes == 1 }
        XCTAssertTrue(closed, "Unexpected recognizer completion must stop, not join, a live microphone pump")
        XCTAssertTrue(harness.insertions.isEmpty)
        if case .failed = harness.controller.phase {} else { XCTFail("Expected a visible interruption") }
    }

    func testCancelledPreparationDoesNotMasqueradeAsUserCancellationAndCanRestart() async {
        for text in ["No borres estas notas.", "Don’t delete these notes."] {
            let harness = Harness(text: text)
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

    func testCancelledRecognizerFailsWithoutDeliveryEvenAfterAnAcceptedStop() async {
        for text in ["No borres estas notas.", "Don’t delete these notes."] {
            for acceptedStop in [false, true] {
                let harness = Harness(text: text)
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
                XCTAssertEqual(harness.finishes, 1)
                XCTAssertEqual(harness.controller.partialText, text)
                XCTAssertTrue(harness.insertions.isEmpty)
            }
        }
    }

    func testAcceptedStopIsExactlyOnceAndCannotAuthorizeTheNextSession() async {
        let controller = DictationController(presentsPanel: false)
        let first = Harness(text: "No borres estas notas.", controller: controller)
        let second = Harness(text: "Don’t delete these notes.", controller: controller)
        defer { controller.cancel() }
        controller.toggle(using: first.dependencies)
        let ready = await awaitEventually { controller.partialText == first.text }
        XCTAssertTrue(ready)
        first.now = first.now.addingTimeInterval(0.75)
        for _ in 0..<3 { controller.toggle(using: first.dependencies) }
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
            let harness = Harness(text: text)
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
            let first = Harness(text: text, controller: controller)
            let next = Harness(text: "Keep this new session open.", controller: controller)
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
            let first = Harness(text: "No borres estas notas.", controller: controller)
            let second = Harness(text: "Don’t delete these notes.", controller: controller)
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
                let harness = Harness(text: text)
                let drain = NativeStopGate()
                let prematureDelivery = expectation(description: "No delivery before native Stop returns")
                prematureDelivery.isInverted = true
                await harness.microphone.holdStop { await drain.wait() }
                var dependencies = harness.dependencies
                let insert = dependencies.insert
                dependencies.insert = { value in
                    if !drain.released { prematureDelivery.fulfill() }
                    return await insert(value)
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

    private func finish(_ harness: Harness, waitingOn deadline: FeedbackDeadline) async {
        var dependencies = harness.dependencies
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
    }

    private func awaitEventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

@MainActor
private final class Harness {
    let controller: DictationController
    let microphone = ControlledDictationMicrophone()
    let defaults = UserDefaults(suiteName: "dictation-tests-\(UUID().uuidString)")!
    let text: String
    var now = Date(timeIntervalSince1970: 1_000)
    var loads = 0
    var finishes = 0
    var hints: TranscriptionHints?
    var transcriptOutput: AsyncThrowingStream<TranscriptSegment, Error>.Continuation?
    var insertions: [String] = []
    let consumerGate: PreparationGate?

    init(
        text: String, consumerGate: PreparationGate? = nil,
        controller: DictationController = DictationController(presentsPanel: false)
    ) {
        self.controller = controller
        self.text = text
        self.consumerGate = consumerGate
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
    }

    func set(_ value: Any, forKey key: String) {
        var values = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        values[key] = value
        defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
    }

    var dependencies: DictationSessionDependencies {
        DictationSessionDependencies(
            makeMicrophone: { [microphone] in .init(source: microphone, warmUp: {}) },
            acquireRuntime: { [weak self] in
                guard let self else { throw CancellationError() }
                self.loads += 1
                return LiveTranscriptionRuntime(engine: ControlledDictationEngine(
                    text: self.text, consumerGate: self.consumerGate,
                    receivedHints: { [weak self] in self?.hints = $0 },
                    receivedOutput: { [weak self] in self?.transcriptOutput = $0 })) { [weak self] in
                    self?.finishes += 1
                }
            },
            canInsert: { true }, targetName: { "Disposable receiver" },
            insert: { [weak self] text in
                self?.insertions.append(text)
                return .inserted
            },
            defaults: defaults, now: { [weak self] in self?.now ?? .distantPast })
    }
}

private actor ControlledDictationMicrophone: CaptureReportingSource {
    private struct Health: Sendable {
        var failure: PortavozCore.CaptureFailure?
        var handler: (@Sendable () -> Void)?
    }

    nonisolated let channel = AudioChannel.microphone
    private nonisolated let health = OSAllocatedUnfairLock(initialState: Health())
    private(set) var starts = 0
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    private var stopDrain: (@Sendable () async -> Void)?

    func holdStop(_ drain: @escaping @Sendable () async -> Void) {
        stopDrain = drain
    }

    nonisolated var captureReport: CaptureChannelReport {
        health.withLock { CaptureChannelReport(channel: .microphone, failure: $0.failure) }
    }

    nonisolated func setCaptureFailureHandler(_ handler: @escaping @Sendable () -> Void) {
        let failed = health.withLock { state in
            state.handler = handler
            return state.failure != nil
        }
        if failed { handler() }
    }

    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        starts += 1
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        continuation.yield(AudioChunk(
            channel: .microphone, samples: [0.1], sampleRate: 16_000, timestamp: 0))
        return stream
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
        await stopDrain?()
    }

    func fail(_ error: any Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }

    func send(_ chunk: AudioChunk) {
        continuation?.yield(chunk)
    }

    func signalFailure(_ failure: PortavozCore.CaptureFailure) {
        let handler = health.withLock { state in
            state.failure = failure
            return state.handler
        }
        handler?()
    }

    func finishWithUnnotifiedFailure() {
        health.withLock { $0.failure = .sourceFailed }
        continuation?.finish()
        continuation = nil
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

private struct ControlledDictationEngine: TranscriptionEngine {
    let text: String
    let consumerGate: PreparationGate?
    let receivedHints: @MainActor @Sendable (TranscriptionHints) -> Void
    let receivedOutput: @MainActor @Sendable (AsyncThrowingStream<TranscriptSegment, Error>.Continuation) -> Void
    let descriptor = EngineDescriptor(
        id: "controlled", displayName: "Controlled", realTimeFactor: 0,
        runsOnDevice: true, approximateMemoryMB: 0)

    func transcribe(
        _ audio: AsyncStream<AudioChunk>, hints: TranscriptionHints
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptSegment.self)
        let task = Task {
            await receivedOutput(continuation)
            await receivedHints(hints)
            var isFirst = true
            for await _ in audio {
                if isFirst {
                    continuation.yield(TranscriptSegment(
                        meetingID: hints.meetingID!, channel: .microphone,
                        text: text, startTime: 0, endTime: 1))
                    isFirst = false
                    await consumerGate?.wait()
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

private enum SyntheticCaptureFailure: Error { case disconnected }

@MainActor
private final class PreparationGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
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
