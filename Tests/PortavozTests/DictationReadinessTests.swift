import ApplicationKit
import AudioCaptureKit
import Foundation
import PortavozCore
import TranscriptionKit
import XCTest

@testable import portavoz_app

@MainActor
final class DictationReadinessTests: XCTestCase {
    func testDelayedFirstBufferDoesNotCountPreparationTowardMinimumCapture() async {
        for text in ["No borres estas notas", "Don’t delete these notes"] {
            for elapsed in [0.0, 0.74, 0.75] {
                let harness = ReadinessHarness(text: text)
                harness.controller.toggle(using: harness.dependencies)
                let opened = await eventually { harness.engineStarted }
                XCTAssertTrue(opened)

                // Opening the stream is not evidence that its device supplied audio.
                // Empty callbacks before the first PCM must not start that clock either.
                harness.now += 10
                await harness.microphone.emit(samples: [])
                let emptyConsumed = await eventuallyAsync { await harness.microphone.pulls >= 2 }
                XCTAssertTrue(emptyConsumed)
                harness.now += 10
                await harness.microphone.emit(samples: [0.1, -0.1])
                let partial = await eventually { harness.controller.partialText == text }
                XCTAssertTrue(partial)
                harness.now += elapsed
                harness.controller.toggle(using: harness.dependencies)
                let finished = await eventually { harness.finishes == 1 }
                XCTAssertTrue(finished)
                XCTAssertEqual(
                    harness.insertions, elapsed < 0.75 ? [] : [text],
                    "Only time after the first real PCM may admit delivery (\(elapsed)s)")
                harness.controller.cancel()
            }
        }
    }

    func testFinishWithoutFirstBufferCancelsImmediatelyInsteadOfAddingTail() async {
        let harness = ReadinessHarness(text: "No audio, no delivery")
        harness.controller.toggle(using: harness.dependencies)
        let opened = await eventually { harness.engineStarted }
        XCTAssertTrue(opened)
        harness.now += 10
        harness.controller.toggle(using: harness.dependencies)
        XCTAssertEqual(harness.controller.phase, .idle)
        let finished = await eventually { harness.finishes == 1 }
        XCTAssertTrue(finished)
        XCTAssertTrue(harness.insertions.isEmpty)
        harness.controller.cancel()
    }

    func testCancelledCaptureKeepsRuntimeUntilNativeStopCompletes() async {
        let harness = ReadinessHarness(text: "Cleanup is still active")
        await harness.microphone.holdStop()
        harness.controller.toggle(using: harness.dependencies)
        let opened = await eventually { harness.engineStarted }
        XCTAssertTrue(opened)
        await harness.microphone.emit(samples: [0.1])
        let partial = await eventually { harness.controller.partialText == harness.text }
        XCTAssertTrue(partial)
        harness.controller.cancel()
        let stopping = await eventuallyAsync { await harness.microphone.stopCalls > 0 }
        XCTAssertTrue(stopping)
        // Drain the actor/consumer turns without releasing the native operation.
        // This is an ownership assertion, not a performance deadline.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(harness.finishes, 0, "Native cleanup still owns the model lease")
        XCTAssertTrue(harness.insertions.isEmpty)
        await harness.microphone.releaseStop()
        let finished = await eventually { harness.finishes == 1 }
        XCTAssertTrue(finished)
        XCTAssertEqual(harness.controller.phase, .idle)
    }

    func testFixtureRecoverySurvivesFreshDependenciesForEachMenuInvocation() async throws {
        for scenario in ["-seed-dictation-microphone-denied", "-seed-dictation-microphone-no-audio"] {
            let controller = DictationController(presentsPanel: false)
            let services = try AppServices(
                arguments: ["-use-temp-store", "-seed-dictation", scenario],
                environment: [:], dictation: controller)
            var first = services.makeDictationSessionDependencies()
            first.waitForFirstBufferDeadline = {}
            controller.toggle(using: first)
            let failed = await eventually {
                if case .failed = controller.phase { return true }
                return false
            }
            XCTAssertTrue(failed)
            controller.cancel()
            // AppServices builds new dependencies on every menu/hotkey call.
            // Recovery state belongs to its one fixture, not that short-lived value.
            controller.toggle(using: services.makeDictationSessionDependencies())
            let recovered = await eventually { controller.partialText == "No borres estas notas." }
            XCTAssertTrue(recovered, scenario)
            XCTAssertEqual(controller.phase, .listening)
            controller.cancel()
        }
    }

    func testMicrophoneDenialDoesNotConstructSourceOrLoadRuntime() async {
        let harness = ReadinessHarness(text: "No permission, no capture")
        var dependencies = harness.dependencies
        dependencies.authorizeMicrophone = { false }
        harness.controller.toggle(using: dependencies)
        let rejected = await eventually {
            if case .failed = harness.controller.phase { return true }
            return false
        }
        XCTAssertTrue(rejected)
        XCTAssertEqual(harness.sourceCreations, 0)
        XCTAssertEqual(harness.runtimeLoads, 0)
        XCTAssertFalse(harness.controller.isActive)
        XCTAssertTrue(harness.insertions.isEmpty)
        harness.controller.cancel()
    }

    func testMissingDeviceFailsBeforeTranscriptionAndReleasesItsRuntime() async {
        let harness = ReadinessHarness(text: "The selected microphone disappeared")
        await harness.microphone.failOpening()
        harness.controller.toggle(using: harness.dependencies)
        let rejected = await eventually {
            if case .failed = harness.controller.phase { return true }
            return false
        }
        XCTAssertTrue(rejected)
        let cleaned = await eventually { harness.finishes == 1 }
        XCTAssertTrue(cleaned)
        XCTAssertFalse(harness.engineStarted)
        XCTAssertTrue(harness.insertions.isEmpty)
        XCTAssertEqual(harness.controller.phase, .failed(
            L10n.text("No microphone is available. Choose an input in Audio settings and try again.")))
        harness.controller.cancel()
    }

    func testAppSettingsWriteRejectsPreparationAndAllowsApplyAfterCancel() async throws {
        let services = try AppServices(
            arguments: ["-use-temp-store"], environment: [:],
            dictation: DictationController(presentsPanel: false))
        let before = try services.portableSettingsSnapshot()
        // An empty review cannot mutate defaults even if the capture guard regresses.
        let review = try PortableSettingsTransfer.review(
            PortableSettingsTransfer.export([:]), current: before)
        let permission = ReadinessSignal()
        var dependencies = DictationUITestFixture.dependencies(fixture: nil)
        dependencies.canInsert = { true }
        dependencies.authorizeMicrophone = { await permission.wait(); return true }
        services.dictation.toggle(using: dependencies)
        let requested = await eventuallyAsync { await permission.started }
        XCTAssertTrue(requested)
        XCTAssertEqual(services.dictation.phase, .preparing)
        XCTAssertThrowsError(try services.applyPortableSettings(review)) {
            XCTAssertEqual($0 as? PortableSettingsFailure, .captureActive)
        }
        XCTAssertEqual(try services.portableSettingsSnapshot(), before)
        services.dictation.cancel()
        await permission.release()
        XCTAssertEqual(try services.applyPortableSettings(review), 0)
        XCTAssertEqual(try services.portableSettingsSnapshot(), before)
    }

    func testLatePermissionAfterCancellationNeverConstructsMicrophone() async {
        let harness = ReadinessHarness(text: "No delayed side effects")
        let permission = ReadinessSignal()
        var dependencies = harness.dependencies
        dependencies.authorizeMicrophone = { await permission.wait(); return true }
        harness.controller.toggle(using: dependencies)
        let requested = await eventuallyAsync { await permission.started }
        XCTAssertTrue(requested)
        XCTAssertEqual(harness.controller.phase, .preparing)
        XCTAssertTrue(harness.controller.isActive)
        harness.controller.cancel()
        await permission.release()
        let returned = await eventuallyAsync { await permission.returned }
        XCTAssertTrue(returned)
        XCTAssertEqual(harness.sourceCreations, 0)
        XCTAssertEqual(harness.runtimeLoads, 0)
        XCTAssertTrue(harness.insertions.isEmpty)
    }

    func testFirstBufferDeadlineCoversWarmUpAndStreamOpeningWithoutEarlyLeaseRelease() async {
        for holdWarmUp in [true, false] {
            let harness = ReadinessHarness(text: "Native preparation did not finish")
            let nativePreparation = ReadinessSignal()
            let deadline = ReadinessSignal()
            var dependencies = harness.dependencies
            if holdWarmUp {
                dependencies.makeMicrophone = { [microphone = harness.microphone] in
                    .init(source: microphone, warmUp: { await nativePreparation.wait() })
                }
            } else {
                await harness.microphone.holdStart(until: nativePreparation)
            }
            dependencies.waitForFirstBufferDeadline = { await deadline.wait() }
            harness.controller.toggle(using: dependencies)
            let preparing = await eventuallyAsync {
                let inputStarted = await nativePreparation.started
                let deadlineStarted = await deadline.started
                return inputStarted && deadlineStarted
            }
            XCTAssertTrue(preparing)
            await deadline.release()
            let rejected = await eventually {
                if case .failed = harness.controller.phase { return true }
                return false
            }
            XCTAssertTrue(rejected)
            XCTAssertEqual(harness.finishes, 0, "The underlying native operation is still owned")
            await nativePreparation.release()
            let cleaned = await eventually { harness.finishes == 1 }
            XCTAssertTrue(cleaned)
            XCTAssertFalse(harness.engineStarted)
            XCTAssertTrue(harness.insertions.isEmpty)
            harness.controller.cancel()
        }
    }

    func testEmptyBuffersDoNotCancelDeadlineButSilentPCMDoes() async {
        for samples: [Float] in [[], [0, 0, 0]] {
            let harness = ReadinessHarness(text: "Silence is valid PCM")
            let deadline = ReadinessSignal()
            var dependencies = harness.dependencies
            dependencies.waitForFirstBufferDeadline = { await deadline.wait() }
            harness.controller.toggle(using: dependencies)
            let opened = await eventually { harness.engineStarted }
            XCTAssertTrue(opened)
            await harness.microphone.emit(samples: samples)
            let drained = await eventuallyAsync { await harness.microphone.pulls >= 2 }
            XCTAssertTrue(drained)
            await deadline.release()
            if samples.isEmpty {
                let rejected = await eventually {
                    if case .failed = harness.controller.phase { return true }
                    return false
                }
                XCTAssertTrue(rejected)
                XCTAssertEqual(harness.observedChunks, 0)
            } else {
                let consumed = await eventually { harness.observedChunks == 1 }
                XCTAssertTrue(consumed)
                XCTAssertEqual(harness.controller.phase, .listening)
                XCTAssertEqual(harness.observedChunks, 1)
            }
            harness.controller.cancel()
            let cleaned = await eventually { harness.finishes == 1 }
            XCTAssertTrue(cleaned)
            XCTAssertTrue(harness.insertions.isEmpty)
        }
    }

    func testEarlyStreamTerminationBeforeFirstPCMFailsAtTheController() async {
        for text in ["No borres estas notas", "Don’t delete these notes"] {
            for throwsError in [false, true] {
                for hasEmptyCallback in [false, true] {
                    let harness = ReadinessHarness(text: text)
                    harness.controller.toggle(using: harness.dependencies)
                    let opened = await eventually { harness.engineStarted }
                    XCTAssertTrue(opened)
                    if hasEmptyCallback {
                        await harness.microphone.emit(samples: [])
                        let emptyConsumed = await eventuallyAsync { await harness.microphone.pulls >= 2 }
                        XCTAssertTrue(emptyConsumed)
                    }
                    if throwsError {
                        await harness.microphone.failStream()
                    } else {
                        await harness.microphone.endStream()
                    }
                    let rejected = await eventually {
                        harness.controller.phase == .failed(L10n.text(
                            "No microphone audio arrived. Check the microphone in Audio settings and try again."))
                    }
                    XCTAssertTrue(rejected, "Early stream termination must not complete an empty dictation")
                    let cleaned = await eventually { harness.finishes == 1 }
                    XCTAssertTrue(cleaned)
                    XCTAssertEqual(harness.observedChunks, 0)
                    XCTAssertTrue(harness.insertions.isEmpty)
                    harness.controller.cancel()
                }
            }
        }
    }

    func testInvalidPCMBeforeOrAfterPartialNeverReachesEngineOrInsertion() async {
        let invalid: [([Float], Double, AudioChannel)] = [
            ([.nan], 16_000, .microphone), ([.infinity], 16_000, .microphone),
            ([0.1], 0, .microphone), ([0.1], .nan, .microphone), ([0.1], 16_000, .system)
        ]
        for withPartial in [false, true] {
            for (samples, rate, channel) in invalid {
                let harness = ReadinessHarness(text: "No borres — Don’t delete")
                harness.controller.toggle(using: harness.dependencies)
                let opened = await eventually { harness.engineStarted }
                XCTAssertTrue(opened)
                if withPartial {
                    await harness.microphone.emit(samples: [0.1])
                    let partial = await eventually { harness.controller.partialText == harness.text }
                    XCTAssertTrue(partial)
                }
                await harness.microphone.emit(samples: samples, sampleRate: rate, channel: channel)
                let rejected = await eventually {
                    if case .failed = harness.controller.phase { return true }
                    return false
                }
                XCTAssertTrue(rejected)
                let cleaned = await eventually { harness.finishes == 1 }
                XCTAssertTrue(cleaned)
                XCTAssertEqual(harness.observedChunks, withPartial ? 1 : 0)
                XCTAssertTrue(harness.insertions.isEmpty)
                harness.controller.cancel()
            }
        }
    }

    func testLiveMicrophoneAdapterUsesSelectedUIDOrVisibleNonDestructiveFallback() async {
        let defaults = UserDefaults(suiteName: "microphone-selection-\(UUID().uuidString)")!
        for (stored, expected, fallback) in [
            (nil, nil, false), ("", nil, false), ("default", nil, false),
            ("USB-Café", "USB-Café", false), ("missing", nil, true)
        ] as [(String?, String?, Bool)] {
            defaults.setVolatileDomain(stored.map { ["preferredInputUID": $0] } ?? [:],
                                       forName: UserDefaults.argumentDomain)
            var selected: [String?] = []
            let input = DictationSessionDependencies.liveMicrophone(
                defaults: defaults, isAvailable: { $0 == "USB-Café" }, makeSource: {
                    selected.append($0)
                    return .init(source: ReadinessMicrophone(), warmUp: {})
                })
            XCTAssertEqual(selected, [expected])
            XCTAssertEqual(input.usesSystemFallback, fallback)
            XCTAssertEqual(defaults.object(forKey: "preferredInputUID") as? String, stored)
        }
    }

    func testCorruptInputDefaultsDoNotBecomeDeviceIdentifiers() async {
        let defaults = UserDefaults(suiteName: "microphone-malformed-\(UUID().uuidString)")!
        for malformed: Any in [true, -1, 1.5, ["USB-Café"], ["uid": "USB-Café"]] {
            defaults.setVolatileDomain(["preferredInputUID": malformed], forName: UserDefaults.argumentDomain)
            var lookups = 0
            var creations = 0
            let input = DictationSessionDependencies.liveMicrophone(
                defaults: defaults, isAvailable: { _ in lookups += 1; return false }, makeSource: { identifier in
                    creations += 1
                    XCTAssertNil(identifier)
                    return .init(source: ReadinessMicrophone(), warmUp: {})
                })
            XCTAssertEqual(lookups, 0)
            XCTAssertEqual(creations, 1)
            XCTAssertFalse(input.usesSystemFallback)
            XCTAssertNotNil(defaults.object(forKey: "preferredInputUID"))
        }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func eventuallyAsync(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

@MainActor
private final class ReadinessHarness {
    let controller = DictationController(presentsPanel: false)
    let microphone = ReadinessMicrophone()
    let defaults = UserDefaults(suiteName: "dictation-readiness-\(UUID().uuidString)")!
    let text: String
    var now: TimeInterval = 1_000
    var engineStarted = false
    var sourceCreations = 0
    var runtimeLoads = 0
    var observedChunks = 0
    var finishes = 0
    var insertions: [String] = []

    init(text: String) {
        self.text = text
        defaults.setVolatileDomain([
            DictationController.fillerFilterKey: false
        ], forName: UserDefaults.argumentDomain)
    }

    var dependencies: DictationSessionDependencies {
        DictationSessionDependencies(
            authorizeMicrophone: { true },
            makeMicrophone: { [weak self, microphone] in
                self?.sourceCreations += 1
                return .init(source: microphone, warmUp: {})
            },
            acquireRuntime: { [weak self] in
                guard let self else { throw CancellationError() }
                runtimeLoads += 1
                return LiveTranscriptionRuntime(engine: ReadinessEngine(
                    text: self.text,
                    onStart: { [weak self] in self?.engineStarted = true },
                    onChunk: { [weak self] in self?.observedChunks += 1 }
                )) { [weak self] in self?.finishes += 1 }
            },
            canInsert: { true }, targetName: { "Disposable receiver" },
            insert: { [weak self] text in
                self?.insertions.append(text)
                return .inserted
            },
            defaults: defaults, now: { [weak self] in
                Date(timeIntervalSince1970: self?.now ?? 0)
            })
    }
}

private actor ReadinessMicrophone: AudioCaptureSource {
    nonisolated let channel = AudioChannel.microphone
    private var queued: [AudioChunk] = []
    private var waiting: CheckedContinuation<AudioChunk?, Error>?
    private var ended = false
    private var streamFailure = false
    private(set) var pulls = 0
    private var stopHeld = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var stopCalls = 0
    private var startGate: ReadinessSignal?
    private var openingFails = false

    func failOpening() { openingFails = true }

    func holdStart(until signal: ReadinessSignal) { startGate = signal }

    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        if let startGate { await startGate.wait() }
        if openingFails { throw AudioCaptureError.noInputDevice }
        return AsyncThrowingStream(unfolding: { try await self.next() })
    }

    private func next() async throws -> AudioChunk? {
        pulls += 1
        if !queued.isEmpty { return queued.removeFirst() }
        if streamFailure { throw AudioCaptureError.noInputDevice }
        if ended { return nil }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }

    func endStream() {
        ended = true
        waiting?.resume(returning: nil)
        waiting = nil
    }

    func failStream() {
        streamFailure = true
        waiting?.resume(throwing: AudioCaptureError.noInputDevice)
        waiting = nil
    }

    func emit(samples: [Float], sampleRate: Double = 16_000, channel: AudioChannel = .microphone) {
        guard !ended else { return }
        let chunk = AudioChunk(channel: channel, samples: samples, sampleRate: sampleRate, timestamp: 0)
        if let waiting {
            self.waiting = nil
            waiting.resume(returning: chunk)
        } else {
            queued.append(chunk)
        }
    }

    func holdStop() { stopHeld = true }

    func releaseStop() {
        stopHeld = false
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func stop() async {
        stopCalls += 1
        ended = true
        waiting?.resume(returning: nil)
        waiting = nil
        if stopHeld { await withCheckedContinuation { stopWaiters.append($0) } }
    }
}

private struct ReadinessEngine: TranscriptionEngine {
    let text: String
    let onStart: @MainActor @Sendable () -> Void
    let onChunk: @MainActor @Sendable () -> Void
    let descriptor = EngineDescriptor(
        id: "readiness", displayName: "Readiness fixture", realTimeFactor: 0,
        runsOnDevice: true, approximateMemoryMB: 0)

    func transcribe(
        _ audio: AsyncStream<AudioChunk>, hints: TranscriptionHints
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptSegment.self)
        let task = Task {
            await onStart()
            for await chunk in audio {
                await onChunk()
                guard !chunk.samples.isEmpty else { continue }
                continuation.yield(TranscriptSegment(
                    meetingID: hints.meetingID!, channel: .microphone,
                    text: text, startTime: 0, endTime: 1))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

private actor ReadinessSignal {
    private(set) var started = false
    private(set) var returned = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        started = true
        if !released { await withCheckedContinuation { continuation = $0 } }
        returned = true
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
