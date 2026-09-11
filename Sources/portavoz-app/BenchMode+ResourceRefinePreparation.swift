import ApplicationKit
import Foundation

extension BenchMode {
    /// Exercises the real first-inference path once before repeated Refine
    /// samples. Loading model objects alone does not exercise lazy prediction
    /// work. Every measured sample still owns a separate, cold app process.
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
                    let request = try makeRefineBenchmarkRequest(
                        fixtureURL: configuration.fixtureURL)
                    try await BenchRefineRuntimePreparation.run(
                        outputURL: configuration.outputURL,
                        timeout: .seconds(configuration.timeoutSeconds)
                    ) {
                        let draft = try await services.refineMeeting.draft
                            .execute(request)
                        return draft.segments.count
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

/// Marker publication belongs to the bounded caller, never to model work
/// that could finish after cancellation or timeout.
enum BenchRefineRuntimePreparation {
    @MainActor
    static func run(
        outputURL: URL,
        timeout: Duration,
        operation: @escaping @MainActor @Sendable () async throws -> Int
    ) async throws {
        let segmentCount = try await BenchResourceTimedOperation.run(
            timeout: timeout, operation: operation)
        try Task.checkCancellation()
        guard segmentCount > 0 else {
            throw BenchRefineResourcePreparationError.emptyDraft
        }
        try BenchResourceLaunchProbe.writeMarker(
            to: outputURL, marker: .refineRuntimePrepared)
    }
}

enum BenchSummaryRuntimePreparation {
    static func publish(result: SummaryRegenerationResult, to outputURL: URL?) throws {
        guard let outputURL else { return }
        try Task.checkCancellation()
        guard case .completed(persisted: true) = result else {
            throw BenchSummaryResourceError.unexpectedResult("preparation incomplete")
        }
        try BenchResourceLaunchProbe.writeMarker(
            to: outputURL, marker: .summaryRuntimePrepared)
    }
}
