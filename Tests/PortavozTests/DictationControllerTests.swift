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
            // The controller has issued its own Stop: early-EOF rejection
            // cannot make this report assertion pass by accident.
            await harness.microphone.armUnnotifiedFailureOnStop()
            harness.now = harness.now.addingTimeInterval(1)
            harness.controller.toggle(using: harness.dependencies)
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
        XCTAssertEqual(harness.controller.phase, .idle, "A late notification cannot say nothing was inserted")
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
        XCTAssertNil(DictationUITestFixture(
            arguments: ["-seed-dictation"], usesTemporaryStore: false))
        XCTAssertNil(DictationUITestFixture(arguments: [], usesTemporaryStore: true))
        XCTAssertNotNil(DictationUITestFixture(
            arguments: ["-seed-dictation"], usesTemporaryStore: true))
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
    let controller = DictationController(presentsPanel: false)
    let microphone = ControlledDictationMicrophone()
    let defaults = UserDefaults(suiteName: "dictation-tests-\(UUID().uuidString)")!
    let text: String
    var now = Date(timeIntervalSince1970: 1_000)
    var loads = 0
    var finishes = 0
    var hints: TranscriptionHints?
    var insertions: [String] = []
    let consumerGate: PreparationGate?

    init(text: String, consumerGate: PreparationGate? = nil) {
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
            authorizeMicrophone: { true },
            makeMicrophone: { [microphone] in .init(source: microphone, warmUp: {}) },
            acquireRuntime: { [weak self] in
                guard let self else { throw CancellationError() }
                self.loads += 1
                return LiveTranscriptionRuntime(engine: ControlledDictationEngine(
                    text: self.text, consumerGate: self.consumerGate,
                    receivedHints: { [weak self] in self?.hints = $0 })) { [weak self] in
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
    private var failOnStop = false

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
        if failOnStop {
            health.withLock { $0.failure = .sourceFailed }
            failOnStop = false
        }
        continuation?.finish()
        continuation = nil
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

    func armUnnotifiedFailureOnStop() {
        failOnStop = true
    }
}

private struct ControlledDictationEngine: TranscriptionEngine {
    let text: String
    let consumerGate: PreparationGate?
    let receivedHints: @MainActor @Sendable (TranscriptionHints) -> Void
    let descriptor = EngineDescriptor(
        id: "controlled", displayName: "Controlled", realTimeFactor: 0,
        runsOnDevice: true, approximateMemoryMB: 0)

    func transcribe(
        _ audio: AsyncStream<AudioChunk>, hints: TranscriptionHints
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptSegment.self)
        let task = Task {
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
