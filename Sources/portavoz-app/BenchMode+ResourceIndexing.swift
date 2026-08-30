import ApplicationKit
import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

struct BenchIndexingResourceWorkload {
    let operation: IndexSemanticCorpus
    let runtime: any SemanticEmbeddingRuntimeClient
    let store: MeetingStore
    let expectedSegments: Int

    @MainActor
    func run(
        timeoutSeconds: Int
    ) async throws -> SemanticCorpusIndexingResult {
        do {
            return try await BenchResourceTimedOperation.run(
                timeout: .seconds(timeoutSeconds)
            ) {
                try await runtime.withPreparedEmbedding(
                    allowAssetDownload: false
                ) { embedder in
                    try await operation.all(
                        using: embedder,
                        batchSize: 256)
                }
            }
        } catch BenchResourceTimedOperationError.operationFailed(let message) {
            throw BenchIndexingResourceError.operationFailed(message)
        } catch BenchResourceTimedOperationError.timedOut {
            throw BenchIndexingResourceError.timedOut(timeoutSeconds)
        }
    }

    func validate(
        _ result: SemanticCorpusIndexingResult
    ) async throws {
        let completed = result.embeddedSegments + result.excludedSegments
        guard completed == expectedSegments else {
            throw BenchIndexingResourceError.incomplete(
                expected: expectedSegments,
                actual: completed)
        }
        guard let profile = await runtime.semanticEmbeddingProfile(),
              profile.isValid,
              try await !store.semanticIndexRequiresMaintenance(for: profile)
        else {
            throw BenchIndexingResourceError.incomplete(
                expected: expectedSegments,
                actual: completed)
        }
    }
}

extension BenchMode {
    /// Measures the semantic corpus maintenance operation that Ask currently
    /// drains synchronously and Library search advances one batch at a time.
    @MainActor
    static func runIndexingResourceBenchIfRequested(services: AppServices) {
        let arguments = ProcessInfo.processInfo.arguments
        let configuration: BenchIndexingResourceConfiguration?
        do {
            configuration = try BenchIndexingResourceConfiguration.requested(
                arguments: arguments)
        } catch {
            emitIndexing(
                "bench-indexing: setup FAILED: \(error.localizedDescription)")
            exit(1)
        }
        guard let configuration else { return }
        guard arguments.contains("-use-temp-store") else {
            emitIndexing("bench-indexing: -use-temp-store is required")
            exit(1)
        }
        let probe: BenchResourceScenarioProbe
        do {
            probe = try BenchResourceScenarioProbe(arguments: arguments)
        } catch {
            emitIndexing(
                "bench-indexing: probe setup FAILED: \(error.localizedDescription)")
            exit(1)
        }

        setbuf(stdout, nil)
        Task { @MainActor in
            do {
                let workloads = try await prepareIndexingResourceWorkloads(
                    services: services,
                    iterations: configuration.iterations,
                    scratchRoot: probe.outputURL(named: "indexing-stores"))
                try await probe.measure(scenario: "indexing") {
                    for workload in workloads {
                        try Task.checkCancellation()
                        let result = try await workload.run(
                            timeoutSeconds: configuration.timeoutSeconds)
                        try await workload.validate(result)
                    }
                }
                emitIndexing("bench-indexing: resource sample complete")
                exit(0)
            } catch {
                probe.cancel()
                emitIndexing(
                    "bench-indexing: FAILED: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    @MainActor
    static func prepareIndexingResourceWorkload(
        services: AppServices
    ) async throws -> BenchIndexingResourceWorkload {
        try await prepareIndexingResourceWorkload(
            store: services.store,
            runtime: services.semanticEmbeddingRuntime,
            telemetry: services.workloadTelemetry,
            iteration: 1,
            prepareRuntime: true)
    }

    @MainActor
    private static func prepareIndexingResourceWorkloads(
        services: AppServices,
        iterations: Int,
        scratchRoot: URL
    ) async throws -> [BenchIndexingResourceWorkload] {
        var workloads = [try await prepareIndexingResourceWorkload(
            services: services)]
        guard iterations > 1 else { return workloads }
        for iteration in 2...iterations {
            let databaseURL = scratchRoot.appendingPathComponent(
                "iteration-\(iteration).sqlite")
            let store = try MeetingStore(databaseURL: databaseURL)
            workloads.append(try await prepareIndexingResourceWorkload(
                store: store,
                runtime: services.semanticEmbeddingRuntime,
                telemetry: services.workloadTelemetry,
                iteration: iteration,
                prepareRuntime: false))
        }
        return workloads
    }

    @MainActor
    private static func prepareIndexingResourceWorkload(
        store: MeetingStore,
        runtime: any SemanticEmbeddingRuntimeClient,
        telemetry: ResourceWorkloadTelemetry,
        iteration: Int,
        prepareRuntime: Bool
    ) async throws -> BenchIndexingResourceWorkload {
        guard await runtime.hasAvailableAssets else {
            throw BenchIndexingResourceError.assetsNotReady
        }
        if prepareRuntime {
            do {
                try await runtime.prepare(allowAssetDownload: false)
            } catch {
                throw BenchIndexingResourceError.assetsNotReady
            }
        }
        let fixture = makeIndexingBenchmarkFixture(iteration: iteration)
        try await store.saveImportedMeeting(
            fixture.meeting,
            speakers: fixture.speakers,
            segments: fixture.segments)
        return BenchIndexingResourceWorkload(
            operation: IndexSemanticCorpus(
                store: store,
                telemetry: telemetry),
            runtime: runtime,
            store: store,
            expectedSegments: fixture.segments.count)
    }

    private static func makeIndexingBenchmarkFixture(iteration: Int) -> (
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) {
        let segmentCount = 1_024
        let now = Date()
        let title = iteration == 1
            ? "Semantic indexing resource benchmark"
            : "Semantic indexing resource benchmark \(iteration)"
        let meeting = Meeting(
            title: title,
            startedAt: now.addingTimeInterval(-TimeInterval(segmentCount * 3)),
            endedAt: now,
            language: "en")
        let speaker = Speaker(
            meetingID: meeting.id,
            label: "S1",
            displayName: "Public fixture")
        let segments = (0..<segmentCount).map { index in
            let prefix = iteration == 1
                ? "Public indexing turn \(index)"
                : "Public indexing run \(iteration), turn \(index)"
            return TranscriptSegment(
                meetingID: meeting.id,
                speakerID: speaker.id,
                channel: .system,
                text: """
                    \(prefix): local search preserves cited \
                    evidence while optional maintenance yields to active recording.
                    """,
                language: "en",
                startTime: TimeInterval(index * 3),
                endTime: TimeInterval(index * 3 + 2),
                isFinal: true)
        }
        return (meeting, [speaker], segments)
    }

    private static func emitIndexing(_ line: String) {
        print(line)
        fflush(stdout)
    }
}
