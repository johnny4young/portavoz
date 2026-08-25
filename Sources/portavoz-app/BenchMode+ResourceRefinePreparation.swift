import Foundation

extension BenchMode {
    /// Prepares the host-level Whisper/Core ML runtime cache once before the
    /// three independent Refine resource processes are measured. Each sample
    /// still starts without an app-resident runtime; this only prevents a
    /// one-time platform compilation from contaminating one repeated sample.
    @MainActor
    static func runRefineResourcePreparationIfRequested(
        services: AppServices
    ) {
        let arguments = ProcessInfo.processInfo.arguments
        let configuration: BenchRefinePreparationConfiguration?
        do {
            configuration = try BenchRefinePreparationConfiguration
                .requested(arguments: arguments)
        } catch {
            emit(
                "bench-refine-preparation: setup FAILED: "
                    + error.localizedDescription)
            exit(1)
        }
        guard let configuration else { return }

        setbuf(stdout, nil)
        Task { @MainActor in
            do {
                try await verifyRefineBenchmarkModels(services: services)
                do {
                    try await BenchResourceTimedOperation.run(
                        timeout: .seconds(configuration.timeoutSeconds)
                    ) {
                        let whisper = try await services.acquireWhisperRuntime(
                            progress: { _ in })
                        guard services.finishWhisperRuntime(whisper) else {
                            throw BenchRefineResourcePreparationError
                                .residencyFailed
                        }
                        let diarization = try await services
                            .acquireDiarizationRuntime()
                        guard services.finishDiarizationRuntime(diarization) else {
                            throw BenchRefineResourcePreparationError
                                .residencyFailed
                        }
                    }
                } catch BenchResourceTimedOperationError.operationFailed(
                    let message
                ) {
                    throw BenchRefineResourcePreparationError
                        .operationFailed(message)
                } catch BenchResourceTimedOperationError.timedOut {
                    throw BenchRefineResourcePreparationError
                        .timedOut(configuration.timeoutSeconds)
                }
                try BenchResourceLaunchProbe.writeMarker(
                    to: configuration.outputURL,
                    marker: .refineRuntimePrepared)
                emit("bench-refine-preparation: runtime prepared")
                exit(0)
            } catch {
                emit(
                    "bench-refine-preparation: FAILED: "
                        + error.localizedDescription)
                exit(1)
            }
        }
    }
}
