import ApplicationKit
import Darwin
import Foundation
import IntelligenceKit
import PortavozCore

private struct AskResourceBenchmark {
    let useCase: AskMeetings
    let question: String
    let meeting: Meeting
    let segments: [TranscriptSegment]
    let ordinalBySegmentID: [UUID: Int]
    let corpusChecksum: String
    let pendingAtSeed: Int
    let pendingBefore: Int
}

extension BenchMode {
    /// `portavoz-app --bench-resource-ask` measures the released deep Ask
    /// workflow over a disposable fixed transcript. Corpus preparation occurs
    /// before measurement; the sample includes query expansion, read-only
    /// hybrid retrieval, and generated answer.
    @MainActor
    static func runAskResourceBenchIfRequested(services: AppServices) {
        let arguments = ProcessInfo.processInfo.arguments
        let configuration: BenchAskResourceConfiguration?
        do {
            configuration = try BenchAskResourceConfiguration.requested(
                arguments: arguments)
        } catch {
            emit("bench-ask: setup FAILED: \(error.localizedDescription)")
            exit(1)
        }
        guard let configuration else { return }
        guard arguments.contains("-use-temp-store") else {
            emit("bench-ask: -use-temp-store is required")
            exit(1)
        }
        let probe: BenchResourceScenarioProbe
        do {
            probe = try BenchResourceScenarioProbe(arguments: arguments)
        } catch {
            emit("bench-ask: probe setup FAILED: \(error.localizedDescription)")
            exit(1)
        }

        setbuf(stdout, nil)
        Task { @MainActor in
            do {
                try await executeAskResourceBenchmark(
                    services: services,
                    configuration: configuration,
                    probe: probe)
                emit("bench-ask: resource sample complete")
                exit(0)
            } catch {
                probe.cancel()
                emit("bench-ask: FAILED: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    @MainActor
    private static func executeAskResourceBenchmark(
        services: AppServices,
        configuration: BenchAskResourceConfiguration,
        probe: BenchResourceScenarioProbe
    ) async throws {
        let benchmark = try await makeAskBenchmark(services: services)
        let pipelineProbe = try AskPipelineRunProbe(run: probe.runIdentifier)
        var observer: UUID? = AppAskPipelineTelemetry.shared.addObserver(
            pipelineProbe.receive)
        defer {
            if let observer {
                AppAskPipelineTelemetry.shared.removeObserver(observer)
            }
        }

        let citations = try await probe.measure(scenario: "ask") {
            var canonical: AskPipelineCitationEvidence?
            for iteration in 0..<configuration.iterations {
                try Task.checkCancellation()
                let answer = try await runAskBenchmark(
                    useCase: benchmark.useCase,
                    question: benchmark.question,
                    timeoutSeconds: configuration.timeoutSeconds)
                guard !answer.citations.isEmpty else {
                    throw BenchAskResourceError.noCitations
                }
                guard let generated = answer.generatedText,
                      !generated.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty
                else {
                    throw BenchAskResourceError.noGeneratedAnswer
                }
                let evidence = try askCitationEvidence(
                    answer.citations,
                    benchmark: benchmark)
                if let canonical, evidence != canonical {
                    throw BenchAskResourceError.unstableCitations
                }
                canonical = evidence
                if iteration == 0, let firstObserver = observer {
                    AppAskPipelineTelemetry.shared.removeObserver(firstObserver)
                    observer = nil
                }
            }
            guard let canonical else {
                throw BenchAskResourceError.noCitations
            }
            return canonical
        }
        let pendingAfter = try await services.store.segmentsNeedingEmbeddings(
            limit: benchmark.segments.count + 1).count
        try pipelineProbe.writeSample(
            to: probe.outputURL(named: "ask-pipeline"),
            corpus: AskPipelineCorpusEvidence(
                generation: "ask-resource-v2",
                checksum: benchmark.corpusChecksum,
                fixtureSegmentCount: benchmark.segments.count,
                pendingAtSeed: benchmark.pendingAtSeed,
                pendingBefore: benchmark.pendingBefore,
                pendingAfter: pendingAfter,
                readyBefore: benchmark.pendingBefore == 0,
                readyAfter: pendingAfter == 0,
                warmup: "preindexed"),
            citations: citations)
    }

    @MainActor
    private static func makeAskBenchmark(
        services: AppServices
    ) async throws -> AskResourceBenchmark {
        guard #available(macOS 26.0, *),
              FoundationModelSummaryProvider.unavailabilityReason() == nil
        else {
            throw BenchAskResourceError.assetsNotReady
        }
        guard await services.semanticEmbeddingRuntime.hasAvailableAssets else {
            throw BenchAskResourceError.assetsNotReady
        }
        let fixture = makeIntelligenceBenchmarkFixture()
        try await services.store.saveImportedMeeting(
            fixture.meeting,
            speakers: fixture.speakers,
            segments: fixture.segments)
        let pendingAtSeed = try await services.store
            .segmentsNeedingEmbeddings(limit: fixture.segments.count + 1).count
        _ = try await services.semanticEmbeddingRuntime.withPreparedEmbedding(
            allowAssetDownload: false
        ) { embedder in
            try await services.semanticIndexingCoordinator.all(
                using: embedder,
                batchSize: 256)
        }
        let pendingBefore = try await services.store
            .segmentsNeedingEmbeddings(limit: fixture.segments.count + 1).count
        return AskResourceBenchmark(
            useCase: AskMeetings.local(
                store: services.store,
                semanticRuntime: services.semanticEmbeddingRuntime,
                pipelineTelemetry: AppAskPipelineTelemetry.shared.telemetry),
            question: "What did we decide about background indexing during active calls?",
            meeting: fixture.meeting,
            segments: fixture.segments,
            ordinalBySegmentID: Dictionary(uniqueKeysWithValues:
                fixture.segments.enumerated().map { ($1.id, $0) }),
            corpusChecksum: askCorpusChecksum(fixture),
            pendingAtSeed: pendingAtSeed,
            pendingBefore: pendingBefore)
    }

    private static func askCorpusChecksum(
        _ fixture: (
            meeting: Meeting,
            speakers: [Speaker],
            segments: [TranscriptSegment]
        )
    ) -> String {
        let labels = Dictionary(uniqueKeysWithValues:
            fixture.speakers.map { ($0.id, $0.label) })
        let components = [fixture.meeting.title]
            + fixture.segments.enumerated().map { index, segment in
                [
                    String(index),
                    segment.speakerID.flatMap { labels[$0] } ?? "unknown",
                    segment.channel.rawValue,
                    segment.language ?? "",
                    String(segment.startTime.bitPattern, radix: 16),
                    String(segment.endTime.bitPattern, radix: 16),
                    segment.text
                ].joined(separator: "|")
            }
        return OperationFingerprint.make(
            version: "ask-resource-corpus-v1",
            components: components)
    }

    private static func askCitationEvidence(
        _ citations: [AskCitation],
        benchmark: AskResourceBenchmark
    ) throws -> AskPipelineCitationEvidence {
        let segmentsByID = Dictionary(uniqueKeysWithValues:
            benchmark.segments.map { ($0.id, $0) })
        var seen = Set<UUID>()
        var ordinals: [String] = []
        for citation in citations {
            guard let segmentID = citation.segmentID,
                  seen.insert(segmentID).inserted,
                  let expected = segmentsByID[segmentID],
                  citation.meetingID == benchmark.meeting.id,
                  citation.meetingTitle == benchmark.meeting.title,
                  citation.timestamp == expected.startTime,
                  citation.text == expected.text,
                  let ordinal = benchmark.ordinalBySegmentID[segmentID]
            else {
                throw BenchAskResourceError.invalidCitations
            }
            ordinals.append(String(ordinal))
        }
        guard !ordinals.isEmpty else {
            throw BenchAskResourceError.noCitations
        }
        return AskPipelineCitationEvidence(
            count: ordinals.count,
            digest: OperationFingerprint.make(
                version: "ask-resource-citations-v1",
                components: ordinals),
            valid: true)
    }

    @MainActor
    private static func runAskBenchmark(
        useCase: AskMeetings,
        question: String,
        timeoutSeconds: Int
    ) async throws -> AskMeetingAnswer {
        do {
            return try await BenchResourceTimedOperation.run(
                timeout: .seconds(timeoutSeconds)
            ) {
                try await useCase.answer(
                    question,
                    source: .library,
                    limit: 6)
            }
        } catch BenchResourceTimedOperationError.operationFailed(let message) {
            throw BenchAskResourceError.operationFailed(message)
        } catch BenchResourceTimedOperationError.timedOut {
            throw BenchAskResourceError.timedOut(timeoutSeconds)
        }
    }
}
