import ApplicationKit
import AudioCaptureKit
import PortavozCore
import TranscriptionKit
import XCTest

@testable import portavoz_app

@MainActor
final class DictationResourceOwnershipTests: XCTestCase {
    func testDictationProtectsMaintenanceAfterTheMeetingOwnerStops() async throws {
        for language in [[], ["-seed-dictation-english"]] {
            let services = try AppServices(
                arguments: ["-use-temp-store", "-seed-dictation"] + language, environment: [:])
            let controller = DictationController(presentsPanel: false)
            defer { controller.cancel() }
            var finished = false
            var dependencies = services.makeDictationSessionDependencies()
            let acquire = dependencies.acquireRuntime
            dependencies.acquireRuntime = {
                let runtime = try await acquire()
                return LiveTranscriptionRuntime(engine: runtime.engine) {
                    runtime.finish()
                    finished = true
                }
            }
            controller.toggle(using: dependencies)
            let listening = await eventually { !controller.partialText.isEmpty }
            XCTAssertTrue(listening)
            XCTAssertNotEqual(services.resourceCaptureState.current, .inactive,
                              "The actual app composition must protect dictation, not only recording")
            services.recordingPhaseDidChange(.recording)
            services.recordingPhaseDidChange(.idle)
            XCTAssertNotEqual(services.resourceCaptureState.current, .inactive,
                              "Finishing the meeting must not finish a different capture owner")
            XCTAssertEqual(AppResourceGovernorMaintenanceGate.disposition(
                for: ResourceWorkloadDescriptor(
                    workloadClass: .maintenance, kind: .searchIndex, operation: .execute),
                phase: .admission, captureState: services.resourceCaptureState.current), .pause)
            services.requestSearchReconciliation()
            for owner: BackgroundWorkOwner in [.semanticIndex, .memoryGraph] {
                XCTAssertEqual(services.backgroundWork.snapshots[owner]?.phase, .waitingForRecording,
                               "The actual reconciliation entry point must yield to dictation")
            }
            controller.cancel()
            let drained = await eventually { finished && services.resourceCaptureState.current == .inactive }
            XCTAssertTrue(drained)
            XCTAssertEqual(services.resourceCaptureState.current, .inactive)
        }
    }

    func testFinishingDictationCannotReleaseTheMeetingOwner() async throws {
        let services = try AppServices(
            arguments: ["-use-temp-store", "-seed-dictation"], environment: [:])
        let controller = DictationController(presentsPanel: false)
        defer { controller.cancel(); services.recordingPhaseDidChange(.idle) }
        var finished = false
        var dependencies = services.makeDictationSessionDependencies()
        let acquire = dependencies.acquireRuntime
        dependencies.acquireRuntime = {
            let runtime = try await acquire()
            return LiveTranscriptionRuntime(engine: runtime.engine) {
                runtime.finish()
                finished = true
            }
        }
        services.recordingPhaseDidChange(.preparing)
        controller.toggle(using: dependencies)
        let listening = await eventually { !controller.partialText.isEmpty }
        XCTAssertTrue(listening)
        controller.cancel()
        let drained = await eventually { finished }
        XCTAssertTrue(drained)
        XCTAssertEqual(services.resourceCaptureState.current, .starting)
        services.recordingPhaseDidChange(.idle)
        XCTAssertEqual(services.resourceCaptureState.current, .inactive)
    }

    func testCancelledOwnerCannotReleaseItsReplacementWhileNativeStopDrains() async throws {
        let services = try AppServices(
            arguments: ["-use-temp-store", "-seed-dictation"], environment: [:])
        let controller = DictationController(presentsPanel: false)
        let microphone = OwnershipHeldMicrophone()
        var firstRetired = false
        var first = services.makeDictationSessionDependencies()
        first.makeMicrophone = { .init(source: microphone, warmUp: {}) }
        let begin = first.beginCapture
        first.beginCapture = {
            let finish = begin()
            return { finish(); firstRetired = true }
        }
        controller.toggle(using: first)
        let firstListening = await eventually { !controller.partialText.isEmpty }
        XCTAssertTrue(firstListening)
        controller.cancel()
        let stopping = await eventuallyAsync { await microphone.stopRequests > 0 }
        XCTAssertTrue(stopping)
        XCTAssertFalse(firstRetired)
        XCTAssertNotEqual(services.resourceCaptureState.current, .inactive)

        controller.toggle(using: services.makeDictationSessionDependencies())
        let nextListening = await eventually { !controller.partialText.isEmpty }
        XCTAssertTrue(nextListening)
        await microphone.releaseStop()
        let retired = await eventually { firstRetired }
        XCTAssertTrue(retired)
        XCTAssertNotEqual(services.resourceCaptureState.current, .inactive,
                          "Retiring the old token must not retire its replacement")
        controller.cancel()
        let allRetired = await eventually { services.resourceCaptureState.current == .inactive }
        XCTAssertTrue(allRetired)
    }

    func testCaptureAdmissionCoversCancelledColdPreparationUntilItActuallyReturns() async throws {
        let services = try AppServices(
            arguments: ["-use-temp-store", "-seed-dictation"], environment: [:])
        let controller = DictationController(presentsPanel: false)
        let gate = OwnershipPreparationGate()
        var preparing = false
        var dependencies = services.makeDictationSessionDependencies()
        let acquire = dependencies.acquireRuntime
        dependencies.acquireRuntime = {
            preparing = true
            await gate.wait()
            return try await acquire()
        }
        controller.toggle(using: dependencies)
        XCTAssertNotEqual(services.resourceCaptureState.current, .inactive,
                          "Acquire protection before the first suspension, not the first audio buffer")
        let started = await eventually { preparing }
        XCTAssertTrue(started)
        controller.cancel()
        XCTAssertNotEqual(services.resourceCaptureState.current, .inactive)
        await gate.release()
        let retired = await eventually { services.resourceCaptureState.current == .inactive }
        XCTAssertTrue(retired)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testPreparationFailureAndDeniedStartLeaveNoCaptureOwner() async throws {
        let services = try AppServices(
            arguments: ["-use-temp-store", "-seed-dictation"], environment: [:])
        let controller = DictationController(presentsPanel: false)
        defer { controller.cancel() }
        var dependencies = services.makeDictationSessionDependencies()
        dependencies.acquireRuntime = { throw OwnershipFailure.unavailable }
        controller.toggle(using: dependencies)
        let failed = await eventually {
            if case .failed = controller.phase { return services.resourceCaptureState.current == .inactive }
            return false
        }
        XCTAssertTrue(failed)
        dependencies.canInsert = { false }
        controller.toggle(using: dependencies)
        XCTAssertEqual(services.resourceCaptureState.current, .inactive)
    }

    func testDuplicateCompletionCannotRemoveAnotherOwnerOrTheMeeting() async throws {
        let services = try AppServices(arguments: ["-use-temp-store"], environment: [:])
        let first = services.beginDictationCapture()
        let second = services.beginDictationCapture()
        first()
        first()
        XCTAssertEqual(services.resourceCaptureState.current, .active)
        services.recordingPhaseDidChange(.preparing)
        second()
        XCTAssertEqual(services.resourceCaptureState.current, .starting)
        services.recordingPhaseDidChange(.idle)
        XCTAssertEqual(services.resourceCaptureState.current, .inactive)
    }

    private func eventually(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    private func eventuallyAsync(_ predicate: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await predicate()
    }
}

private enum OwnershipFailure: Error { case unavailable }

private actor OwnershipPreparationGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor OwnershipHeldMicrophone: AudioCaptureSource {
    nonisolated let channel = AudioChannel.microphone
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    private let stopGate = OwnershipPreparationGate()
    private(set) var stopRequests = 0

    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        continuation.yield(AudioChunk(
            channel: .microphone, samples: [0.1, -0.1], sampleRate: 16_000, timestamp: 0))
        return stream
    }

    func stop() async {
        stopRequests += 1
        continuation?.finish()
        continuation = nil
        await stopGate.wait()
    }

    func releaseStop() async { await stopGate.release() }
}
