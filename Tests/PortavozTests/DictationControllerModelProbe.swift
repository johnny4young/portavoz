import Foundation
import TranscriptionKit

@testable import portavoz_app

@MainActor
enum DictationControllerModelProbe {
    struct Result {
        // Not Encodable: proposed output stays in memory for score comparison.
        let proposedText: String
        let measurement: DictationSessionMeasurement
        let footprint: DictationFootprintObservation.Receipt
        let frames: Int
        let inputCompleted: Bool
    }

    static func run(
        samples: [Float], acquireRuntime: @escaping () async throws -> LiveTranscriptionRuntime,
        pace: @escaping DictationModelProbe.Pace = { try await ContinuousClock().sleep(until: $0) },
        usage: @escaping DictationFootprintObservation.Usage = ResourceProbeUsage.current
    ) async throws -> Result {
        try DictationPCMFeeder.validate(samples)
        try Task.checkCancellation()
        let footprint = try DictationFootprintObservation(usage: usage)
        let microphone = DictationControllerPCMSource(samples: samples, pace: pace)
        let controller = DictationController(presentsPanel: false)
        let (measurements, measured) = AsyncStream.makeStream(
            of: DictationSessionMeasurement.self, bufferingPolicy: .bufferingOldest(1))
        let (releases, released) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingOldest(1))
        var runtimeAcquired = false
        var proposedText = ""
        var inputCompleted = false
        let defaults = UserDefaults(suiteName: "dictation-controller-probe-\(UUID().uuidString)")!
        defaults.setVolatileDomain([
            DictationController.fillerFilterKey: false,
            DictationController.languageKey: "auto",
            DictationController.replacementsKey: "[]", "customVocabulary": ""
        ], forName: UserDefaults.argumentDomain)
        let dependencies = DictationSessionDependencies(
            makeMicrophone: { .init(source: microphone, warmUp: {}) },
            acquireRuntime: {
                let runtime = try await acquireRuntime()
                runtimeAcquired = true
                return LiveTranscriptionRuntime(engine: runtime.engine) {
                    runtime.finish()
                    released.yield(true)
                    released.finish()
                }
            },
            canInsert: { true }, targetName: { nil },
            insert: { text in
                proposedText = text
                // No native permission/focus inspection, clipboard or key event.
                return .focusUnavailable
            },
            defaults: defaults,
            measurementSink: { measured.yield($0); measured.finish() })
        controller.toggle(using: dependencies)
        let stopDriver = Task {
            for await complete in microphone.completion {
                inputCompleted = complete
                guard complete, !Task.isCancelled, controller.phase == .listening else { break }
                controller.toggle(using: dependencies)
            }
        }
        var iterator = measurements.makeAsyncIterator()
        let receipt = await iterator.next()
        stopDriver.cancel()
        controller.cancel()
        await microphone.stop()
        await stopDriver.value
        if runtimeAcquired {
            var releases = releases.makeAsyncIterator()
            _ = await releases.next()
        }
        let resource = try await footprint.finish()
        try Task.checkCancellation()
        guard let receipt else { throw DictationModelProbe.Failure.invalidInput }
        return Result(
            proposedText: proposedText, measurement: receipt, footprint: resource,
            frames: microphone.frames, inputCompleted: inputCompleted)
    }
}
