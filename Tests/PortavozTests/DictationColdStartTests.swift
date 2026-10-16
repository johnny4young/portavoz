import AudioCaptureKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class DictationColdStartTests: XCTestCase {
    func testSpeechDuringColdLoadIsDeliveredOnceTheRuntimeArrives() async {
        for text in ["No borres estas notas", "Don’t delete these notes"] {
            let cold = ColdHarness(text: text)
            cold.harness.controller.toggle(using: cold.dependencies)
            let listening = await eventually { cold.harness.controller.phase == .listening }
            XCTAssertTrue(listening, "First PCM opens listening before the model is ready")
            XCTAssertTrue(cold.harness.controller.isLoadingModel)
            XCTAssertEqual(cold.harness.loads, 0)
            await cold.harness.microphone.send(chunk(seconds: 1))
            cold.harness.now = cold.harness.now.addingTimeInterval(1)
            cold.harness.controller.toggle(using: cold.dependencies)
            let stopped = await eventuallyAsync { await cold.harness.microphone.stops > 0 }
            XCTAssertTrue(stopped, "Stop after the tail does not wait for the model")
            XCTAssertTrue(cold.harness.insertions.isEmpty)

            cold.gate.release()
            let delivered = await eventually { cold.harness.insertions == [text] }
            XCTAssertTrue(delivered)
            let finished = await eventually { cold.harness.finishes == 1 }
            XCTAssertTrue(finished)
            XCTAssertFalse(cold.harness.controller.isLoadingModel)
        }
    }

    func testHeldHotkeyReleasedDuringColdLoadDeliversInsteadOfCancelling() async {
        let cold = ColdHarness(text: "Hold to talk survives a cold model")
        let pressed = cold.harness.now
        cold.harness.controller.handleHotkeyPress(using: cold.dependencies, at: pressed)
        let listening = await eventually { cold.harness.controller.phase == .listening }
        XCTAssertTrue(listening)
        cold.harness.now = cold.harness.now.addingTimeInterval(DictationCapturePolicy.minimumCapture)
        cold.harness.controller.handleHotkeyRelease(at: pressed.addingTimeInterval(1))
        XCTAssertTrue(cold.harness.controller.isActive, "Release during the load is a finish, not a cancel")
        cold.gate.release()
        let delivered = await eventually { cold.harness.insertions == [cold.harness.text] }
        XCTAssertTrue(delivered)
    }

    func testBacklogLimitBoundsAudioHeldForTheModel() async {
        let limit = Int(DictationRelayPolicy.backlogLimit)
        for (pendingSeconds, delivers) in [(limit - 2, true), (limit + 1, false)] {
            let cold = ColdHarness(text: "Bounded pre-roll")
            cold.harness.controller.toggle(using: cold.dependencies)
            let listening = await eventually { cold.harness.controller.phase == .listening }
            XCTAssertTrue(listening)
            for _ in 0..<pendingSeconds {
                await cold.harness.microphone.send(chunk(seconds: 1))
            }
            if delivers {
                let handled = await eventually { cold.harness.controller.micLevel > 0.2 }
                XCTAssertTrue(handled)
                cold.harness.now = cold.harness.now.addingTimeInterval(1)
                cold.harness.controller.toggle(using: cold.dependencies)
                cold.gate.release()
                let delivered = await eventually { cold.harness.insertions == ["Bounded pre-roll"] }
                XCTAssertTrue(delivered, "\(pendingSeconds) s stays within the limit")
            } else {
                let failed = await eventually {
                    cold.harness.controller.phase == .failed(L10n.text(
                        "The speech model took too long to load. Nothing was inserted. Try again in a moment."))
                }
                XCTAssertTrue(failed, "\(pendingSeconds) s exceeds the limit")
                cold.gate.release()
                let finished = await eventually { cold.harness.finishes == 1 }
                XCTAssertTrue(finished, "The late lease is still finished")
                XCTAssertTrue(cold.harness.insertions.isEmpty)
            }
            cold.harness.controller.cancel()
        }
    }

    func testRuntimeFailureAfterMicrophoneOpenedStopsCapture() async {
        let harness = DictationControllerHarness(text: "Never typed")
        let gate = PreparationGate()
        var dependencies = harness.dependencies
        dependencies.acquireRuntime = {
            await gate.wait()
            throw ColdStartFailure.modelUnavailable
        }
        harness.controller.toggle(using: dependencies)
        let listening = await eventually { harness.controller.phase == .listening }
        XCTAssertTrue(listening)
        gate.release()
        let failed = await eventually {
            harness.controller.phase == .failed(LiveSpeechFailureMessage.dictation(ColdStartFailure.modelUnavailable))
        }
        XCTAssertTrue(failed)
        let stops = await harness.microphone.stops
        XCTAssertGreaterThan(stops, 0)
        XCTAssertTrue(harness.insertions.isEmpty)
        XCTAssertEqual(harness.finishes, 0)
    }

    func testStartCuePlaysBeforeTheMicrophoneAndStopAtTheRealStop() async {
        let harness = DictationControllerHarness(text: "Cues")
        var cues: [DictationSoundCue] = []
        var dependencies = harness.dependencies
        dependencies.playCue = { cues.append($0) }
        harness.controller.toggle(using: dependencies)
        XCTAssertEqual(cues, [.start], "Start sounds on the accepted press, before the microphone opens")
        let starts = await harness.microphone.starts
        XCTAssertEqual(starts, 0, "The cue can never be captured")
        let listening = await eventually { harness.controller.phase == .listening }
        XCTAssertTrue(listening)
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
        let delivered = await eventually { harness.insertions == ["Cues"] }
        XCTAssertTrue(delivered)
        XCTAssertEqual(cues, [.start, .stop])

        cues = []
        harness.controller.toggle(using: dependencies)
        let relistening = await eventually { harness.controller.phase == .listening }
        XCTAssertTrue(relistening)
        harness.controller.cancel()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(cues, [.start], "Cancel closes silently")
    }

    func testSoundsAndPrewarmAreOffByDefault() async {
        let defaults = UserDefaults(suiteName: "dictation-cues-\(UUID().uuidString)")!
        XCTAssertFalse(defaults.bool(forKey: DictationSoundCue.defaultsKey))
        XCTAssertFalse(DictationPrewarmPolicy.shouldWarm(.init(
            dictationEnabled: true, prewarmEnabled: defaults.bool(forKey: DictationPrewarmPolicy.defaultsKey),
            profile: .balanced, engine: .parakeet, underPressure: false, lowPowerMode: false,
            temporaryStore: false)))
    }

    func testPrewarmRunsOnlyWhenEveryConditionAllowsIt() async {
        let allowed = DictationPrewarmPolicy.Conditions(
            dictationEnabled: true, prewarmEnabled: true, profile: .balanced, engine: .parakeet,
            underPressure: false, lowPowerMode: false, temporaryStore: false)
        XCTAssertTrue(DictationPrewarmPolicy.shouldWarm(allowed))
        let blocked: [(String, (inout DictationPrewarmPolicy.Conditions) -> Void)] = [
            ("dictation off", { $0.dictationEnabled = false }),
            ("setting off", { $0.prewarmEnabled = false }),
            ("lightweight", { $0.profile = .lightweight }),
            ("apple speech", { $0.engine = .appleSpeech }),
            ("pressure", { $0.underPressure = true }),
            ("low power", { $0.lowPowerMode = true }),
            ("temporary store", { $0.temporaryStore = true }),
        ]
        for (name, change) in blocked {
            var conditions = allowed
            change(&conditions)
            XCTAssertFalse(DictationPrewarmPolicy.shouldWarm(conditions), name)
        }
    }

    func testRelayPolicyMeasuresQueuedAudioTime() async {
        let capacity = DictationRelayPolicy.capacity
        let limit = DictationRelayPolicy.backlogLimit
        let second = chunk(seconds: 1)
        XCTAssertTrue(DictationRelayPolicy.admits(.enqueued(remaining: capacity - Int(limit)), chunk: second))
        XCTAssertFalse(DictationRelayPolicy.admits(.enqueued(remaining: capacity - Int(limit) - 1), chunk: second))
        XCTAssertFalse(DictationRelayPolicy.admits(.dropped(second), chunk: second))
        XCTAssertFalse(DictationRelayPolicy.admits(.terminated, chunk: second))
        // Small hardware buffers reach the 30 s time bound before the chunk backstop.
        let small = AudioChunk(channel: .microphone, samples: [Float](repeating: 0, count: 128),
                               sampleRate: 48_000, timestamp: 0)
        let chunksFor30Seconds = Int(limit * 48_000 / 128)
        XCTAssertLessThanOrEqual(chunksFor30Seconds, capacity)
        XCTAssertTrue(DictationRelayPolicy.admits(.enqueued(remaining: capacity - chunksFor30Seconds), chunk: small))
    }

    private func chunk(seconds: Double) -> AudioChunk {
        AudioChunk(
            channel: .microphone, samples: [Float](repeating: 0.25, count: Int(16_000 * seconds)),
            sampleRate: 16_000, timestamp: 0)
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func eventuallyAsync(_ condition: @escaping @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

/// A controller harness whose model stays cold until the test releases it.
@MainActor
private final class ColdHarness {
    let harness: DictationControllerHarness
    let gate = PreparationGate()
    let dependencies: DictationSessionDependencies

    init(text: String) {
        harness = DictationControllerHarness(text: text)
        var dependencies = harness.dependencies
        let load = dependencies.acquireRuntime
        let gate = gate
        dependencies.acquireRuntime = {
            await gate.wait()
            return try await load()
        }
        self.dependencies = dependencies
    }
}

private enum ColdStartFailure: LocalizedError {
    case modelUnavailable

    var errorDescription: String? { "Model unavailable" }
}
