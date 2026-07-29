import ApplicationKit
import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

struct BenchIndexingResourceWorkload {
    let operation: IndexSemanticCorpus
    let runtime: any SemanticEmbeddingRuntimeClient
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
        _ result: SemanticCorpusIndexingResult,
        store: MeetingStore
    ) async throws {
        let completed = result.embeddedSegments + result.excludedSegments
        guard completed == expectedSegments else {
            throw BenchIndexingResourceError.incomplete(
                expected: expectedSegments,
                actual: completed)
        }
        let remaining = try await store.segmentsNeedingEmbeddings(limit: 1)
        guard remaining.isEmpty else {
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
                let workload = try await prepareIndexingResourceWorkload(
                    services: services)
                let result = try await probe.measure(scenario: "indexing") {
                    try await workload.run(
                        timeoutSeconds: configuration.timeoutSeconds)
                }
                try await workload.validate(
                    result,
                    store: services.store)
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
        let runtime = services.semanticEmbeddingRuntime
        guard await runtime.hasAvailableAssets else {
            throw BenchIndexingResourceError.assetsNotReady
        }
        do {
            try await runtime.prepare(allowAssetDownload: false)
        } catch {
            throw BenchIndexingResourceError.assetsNotReady
        }
        let fixture = makeIndexingBenchmarkFixture()
        try await services.store.saveImportedMeeting(
            fixture.meeting,
            speakers: fixture.speakers,
            segments: fixture.segments)
        return BenchIndexingResourceWorkload(
            operation: IndexSemanticCorpus(
                store: services.store,
                telemetry: services.workloadTelemetry),
            runtime: runtime,
            expectedSegments: fixture.segments.count)
    }

    private static func makeIndexingBenchmarkFixture() -> (
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) {
        let segmentCount = 1_024
        let now = Date()
        let meeting = Meeting(
            title: "Semantic indexing resource benchmark",
            startedAt: now.addingTimeInterval(-TimeInterval(segmentCount * 3)),
            endedAt: now,
            language: "en")
        let speaker = Speaker(
            meetingID: meeting.id,
            label: "S1",
            displayName: "Public fixture")
        let segments = (0..<segmentCount).map { index in
            TranscriptSegment(
                meetingID: meeting.id,
                speakerID: speaker.id,
                channel: .system,
                text: """
                    Public indexing turn \(index): local search preserves cited \
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
