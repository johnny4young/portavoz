import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest
@testable import portavoz_cli

final class AskQualityAttributionTests: XCTestCase {
    func testAttributionPreservesRealCanonicalObservationAndNoPayloadEscapes() async throws {
        let context = try await workspace()
        let corpus = try await AskQualityAttributionBenchmark.prepare(context)
        let options = try options()
        let diagnostic = try await AskQualityAttributionBenchmark.observe(
            fixture: fixture(), context: context, corpus: corpus, options: options)
        let canonical = try await AskQualityProductionBenchmark.observe(
            fixture: fixture(), mapping: context.mapping,
            retrieval: LocalAskMeetingRetrieval(
                store: context.store, queryExpander: AskQualityNoExpansion(), runtime: context.runtime),
            build: options.build, commit: options.commit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(diagnostic.observation), try encoder.encode(canonical))
        XCTAssertEqual(diagnostic.stages.count, 1)
        XCTAssertEqual(diagnostic.stages[0].lexical.first?.unitID, "segment-001")
        XCTAssertEqual(diagnostic.stages[0].semanticRequests.count, 1)
        XCTAssertEqual(diagnostic.stages[0].semanticRequests[0].outcome, .succeeded)
        XCTAssertEqual(corpus.profileFingerprint, AttributionEmbedding.profile.fingerprint)
        XCTAssertEqual(corpus.projectedUnitCount, 3)
        XCTAssertEqual(corpus.embeddedRows, 2)
        XCTAssertEqual(corpus.excludedRows, 1)
        XCTAssertEqual(corpus.embeddingResults.nonzeroFiniteVectors, 1)
        XCTAssertEqual(corpus.embeddingResults.zeroVectors, 1)
        let json = String(decoding: try encoder.encode(diagnostic), as: UTF8.self)
        for secret in ["atlas-private-token", "private query", "Private meeting", "text\"", "timestamp\""] {
            XCTAssertFalse(json.contains(secret), secret)
        }
    }

    func testVectorCountsDistinguishZeroMalformedAndMissingWithoutChangingVectors() async throws {
        let vectors: [[Float]] = [[1, 0], [0, -0], [], [Float.nan, 0], [1], [Float.infinity, 0]]
        let counts = AskQualityVectorCounts.measure(vectors, requested: 7, dimension: 2)
        XCTAssertEqual(counts, AskQualityVectorCounts(
            requestedTexts: 7, returnedVectors: 6, nonzeroFiniteVectors: 1,
            zeroVectors: 1, malformedVectors: 4))
        let wrapper = AskQualityMeasuredEmbedding(
            underlying: AttributionEmbedding(), profile: AttributionEmbedding.profile)
        let actual = try await wrapper.vectors(for: ["zero", "ordinary"])
        XCTAssertEqual(actual, [[0, 0], [1, 0]])
        let measured = await wrapper.counts
        XCTAssertEqual(measured.returnedVectors, 2)
        XCTAssertEqual(measured.zeroVectors, 1)
    }

    func testFailedScanIsNotSuccessfulEmptyScanAndNeverExportsUnderlyingError() async throws {
        let context = try await workspace()
        let corpus = try await AskQualityAttributionBenchmark.prepare(context)
        for mode in [AttributionIndex.Mode.failed, .empty] {
            let index = AttributionIndex(mode: mode)
            let document = try await AskQualityAttributionBenchmark.observe(
                fixture: fixture(), context: context, corpus: corpus,
                options: options(), semanticIndex: index)
            let request = try XCTUnwrap(document.stages.first?.semanticRequests.first)
            XCTAssertEqual(request.outcome, mode == .failed ? .failed : .succeeded)
            XCTAssertEqual(request.variants.count, mode == .failed ? 0 : request.queryVectors.returnedVectors)
            let calls = await index.batchCalls
            XCTAssertEqual(calls, 1)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
                .contains("secret-provider-error"))
            XCTAssertEqual(document.observation.queries[0].hits.first?.unitID, "segment-001")
        }
    }

    func testCancellationFromActualRetrievalDoesNotBecomeFallbackReceipt() async throws {
        let context = try await workspace()
        let corpus = try await AskQualityAttributionBenchmark.prepare(context)
        do {
            _ = try await AskQualityAttributionBenchmark.observe(
                fixture: fixture(), context: context, corpus: corpus,
                options: options(), semanticIndex: AttributionIndex(mode: .cancelled))
            XCTFail("cancelled retrieval must not publish a diagnostic")
        } catch is CancellationError { /* Expected: no fallback receipt. */ }
    }

    func testUnavailableQueryAssetsRemainNotInvokedRatherThanFailed() async throws {
        let context = try await workspace()
        let corpus = try await AskQualityAttributionBenchmark.prepare(context)
        let unavailable = AskQualityWorkspace(store: context.store, mapping: context.mapping,
            runtime: AttributionRuntime(available: false))
        let document = try await AskQualityAttributionBenchmark.observe(
            fixture: fixture(), context: unavailable, corpus: corpus, options: options())
        XCTAssertTrue(document.stages[0].semanticRequests.isEmpty)
        XCTAssertEqual(document.observation.queries[0].hits.first?.unitID, "segment-001")
    }

    func testQueryProfileDriftRejectsEvenLexicalFallback() async throws {
        let context = try await workspace()
        let corpus = try await AskQualityAttributionBenchmark.prepare(context)
        let changed = AttributionDriftingEmbedding()
        _ = await changed.vectors(for: [])
        let altered = AskQualityWorkspace(store: context.store, mapping: context.mapping,
            runtime: AttributionRuntime(embedder: changed))
        do {
            _ = try await AskQualityAttributionBenchmark.observe(
                fixture: fixture(), context: altered, corpus: corpus, options: options())
            XCTFail("cannot attribute evidence to the previous vector space")
        } catch { XCTAssertEqual(error as? AskQualityAttributionError, .profileChanged) }
    }

    func testMeasuredIndexPreservesOneBatchVariantOrderingAndCandidateLimit() async throws {
        let context = try await workspace()
        let firstHits = try await context.store.search("Mara", limit: 1)
        let secondHits = try await context.store.search("zero", limit: 1)
        let first = try XCTUnwrap(firstHits.first)
        let second = try XCTUnwrap(secondHits.first)
        let index = AttributionReturningIndex(hits: [[first, second], [second, first]])
        let recorder = AskQualityStageRecorder(mapping: context.mapping)
        await recorder.begin()
        await recorder.record(AskEvidenceUpdate(phase: .lexical, citations: []))
        await recorder.record(AskEvidenceUpdate(phase: .fused, citations: []))
        let measured = AskQualityMeasuredIndex(underlying: index, recorder: recorder,
                                               profile: AttributionEmbedding.profile)
        let result = try await measured.search([[1, 0], [0, 1]], profile: AttributionEmbedding.profile, limit: 12)
        XCTAssertEqual(result.map { $0.map(\.segmentID) }, [[first.segmentID, second.segmentID],
                                                          [second.segmentID, first.segmentID]])
        let stage = try await recorder.finish(queryID: "query-001", finalHits: [])
        XCTAssertEqual(stage.semanticRequests[0].candidateLimit, 12)
        XCTAssertEqual(stage.semanticRequests[0].variants.map { $0.map(\.unitID) },
                       [["segment-001", "segment-002"], ["segment-002", "segment-001"]])
        let calls = await index.calls
        XCTAssertEqual(calls, 1)
    }

    func testProfileDriftDuringPreparationRejectsReceipt() async throws {
        let context = try await workspace(runtime: AttributionRuntime(embedder: AttributionDriftingEmbedding()))
        do {
            _ = try await AskQualityAttributionBenchmark.prepare(context)
            XCTFail("changed profile must fail closed")
        } catch {
            XCTAssertEqual(error as? AskQualityAttributionError, .profileChanged)
        }
    }

    func testAttributionRejectsDownloadsBeforePreparingWorkspace() async throws {
        do {
            _ = try await AskQualityAttributionBenchmark.run(fixture: fixture(), options: options(download: true))
            XCTFail("attribution never downloads")
        } catch {
            XCTAssertEqual(error as? AskQualityAttributionError, .downloadsForbidden)
        }
    }

    func testRecorderRequiresBothStagesAndExactFinalEvidence() async throws {
        let context = try await workspace()
        let recorder = AskQualityStageRecorder(mapping: context.mapping)
        await recorder.begin()
        do {
            _ = try await recorder.finish(queryID: "query-001", finalHits: [])
            XCTFail("missing callbacks")
        } catch { XCTAssertEqual(error as? AskQualityAttributionError, .incompleteStages) }
        await recorder.record(AskEvidenceUpdate(phase: .lexical, citations: []))
        await recorder.record(AskEvidenceUpdate(phase: .fused, citations: []))
        do {
            _ = try await recorder.finish(queryID: "query-001", finalHits: [AskQualityHitObservation(
                unitID: "segment-001", sourceSegmentIDs: ["segment-001"], meetingID: "meeting-001",
                timestampMilliseconds: 1_000, transcriptRevision: 3)])
            XCTFail("reported fused evidence differs from the actual returned result")
        } catch { XCTAssertEqual(error as? AskQualityAttributionError, .incompleteStages) }
        let empty = try await recorder.finish(queryID: "query-001", finalHits: [])
        XCTAssertTrue(empty.semanticRequests.isEmpty, "not invoked is not a failed scan")
        await recorder.record(AskEvidenceUpdate(phase: .fused, citations: []))
        do {
            _ = try await recorder.finish(queryID: "query-001", finalHits: [])
            XCTFail("duplicate callback")
        } catch { XCTAssertEqual(error as? AskQualityAttributionError, .incompleteStages) }
    }

    func testRecorderRejectsTruncatedSemanticVariantBatch() async throws {
        let context = try await workspace()
        let recorder = AskQualityStageRecorder(mapping: context.mapping)
        await recorder.begin()
        await recorder.record(AskEvidenceUpdate(phase: .lexical, citations: []))
        await recorder.record(AskEvidenceUpdate(phase: .fused, citations: []))
        await recorder.recordSemantic(outcome: .succeeded, profile: AttributionEmbedding.profile,
                                      limit: 12, vectors: [[1, 0], [0, 1]], hits: [[]])
        do {
            _ = try await recorder.finish(queryID: "query-001", finalHits: [])
            XCTFail("missing variant cannot become a successful empty scan")
        } catch { XCTAssertEqual(error as? AskQualityAttributionError, .incompleteStages) }
    }

    private func options(download: Bool = false) throws -> AskQualityBenchmarkOptions {
        try AskQualityBenchmarkOptions(arguments: [
            "--fixture", "/tmp/fixture.json", "--output", "/tmp/attribution.json",
            "--build", "test", "--commit", String(repeating: "a", count: 40),
            "--asset-download", download ? "if-needed" : "never"
        ])
    }

    private func workspace(
        runtime: any SemanticEmbeddingRuntimeClient = AttributionRuntime()
    ) async throws -> AskQualityWorkspace {
        let store = try MeetingStore.inMemory()
        let mapping = try await AskQualityCorpusMapping.seed(fixture: fixture(), store: store)
        return AskQualityWorkspace(store: store, mapping: mapping, runtime: runtime)
    }

    private func fixture() -> AskQualityFixture {
        AskQualityFixture(schemaVersion: 1, kind: "ask-quality-fixture",
            generation: "test", contentSource: "public-synthetic-only",
            segments: [
                segment("001", text: "Mara owns atlas-private-token delivery this Friday."),
                segment("002", text: "zero vector despite a sufficiently long source"),
                segment("003", text: "Short")
            ], queries: [AskQualityFixtureQuery(
                id: "query-001", text: "Who owns atlas-private-token private query?",
                relationship: "englishToEnglish", intent: "name",
                relevant: [AskQualityFixtureRelevant(segmentID: "segment-001", grade: 3,
                    expectedTimestampMilliseconds: 1_000, expectedOwner: "Mara")],
                hardNegativeSegmentIDs: ["segment-002"], answerPolicy: "answer")])
    }

    private func segment(_ suffix: String, text: String) -> AskQualityFixtureSegment {
        AskQualityFixtureSegment(id: "segment-\(suffix)", meetingID: "meeting-001",
            meetingTitle: "Private meeting", timestampMilliseconds: 1_000,
            transcriptRevision: 3, language: "en", owner: "Mara", text: text)
    }
}

private struct AttributionRuntime: SemanticEmbeddingRuntimeClient {
    var embedder: any SemanticTextEmbedding = AttributionEmbedding()
    var available = true
    var hasAvailableAssets: Bool { get async { available } }
    func prepare(allowAssetDownload _: Bool) async throws {}
    func semanticEmbeddingProfile() async -> SemanticEmbeddingProfile? {
        await embedder.semanticEmbeddingProfile()
    }
    func withPreparedEmbedding<Result: Sendable>(
        allowAssetDownload: Bool,
        operation: @Sendable (any SemanticTextEmbedding) async throws -> Result
    ) async throws -> Result {
        XCTAssertFalse(allowAssetDownload)
        return try await operation(embedder)
    }
}

private actor AttributionReturningIndex: SemanticIndexSearching {
    let hits: [[SearchHit]]
    private(set) var calls = 0
    init(hits: [[SearchHit]]) { self.hits = hits }
    func search(_ query: [Float], profile: SemanticEmbeddingProfile, limit: Int) -> [SearchHit] {
        XCTFail("batch wrapper must not decompose one exact scan into individual scans")
        return []
    }
    func search(_ queries: [[Float]], profile: SemanticEmbeddingProfile, limit: Int) -> [[SearchHit]] {
        calls += 1
        XCTAssertEqual(queries, [[1, 0], [0, 1]])
        XCTAssertEqual(limit, 12)
        return hits
    }
}

private struct AttributionEmbedding: SemanticTextEmbedding {
    static let profile = SemanticEmbeddingProfile(modelIdentifier: "test-embedding", modelRevision: 1,
        vectorDimension: 2, pipelineIdentifier: "test", pipelineRevision: 1, vectorSchemaVersion: 1)
    func semanticEmbeddingProfile() async -> SemanticEmbeddingProfile { Self.profile }
    func vectors(for texts: [String]) async throws -> [[Float]] {
        texts.map { $0.contains("zero") ? [0, 0] : [1, 0] }
    }
}

private actor AttributionDriftingEmbedding: SemanticTextEmbedding {
    private var changed = false
    func semanticEmbeddingProfile() -> SemanticEmbeddingProfile {
        SemanticEmbeddingProfile(modelIdentifier: "test-embedding", modelRevision: changed ? 2 : 1,
            vectorDimension: 2, pipelineIdentifier: "test", pipelineRevision: 1, vectorSchemaVersion: 1)
    }
    func vectors(for texts: [String]) -> [[Float]] {
        changed = true
        return texts.map { _ in [1, 0] }
    }
}

private actor AttributionIndex: SemanticIndexSearching {
    enum Mode { case failed, empty, cancelled }
    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "secret-provider-error" }
    }
    let mode: Mode
    private(set) var batchCalls = 0
    init(mode: Mode) { self.mode = mode }
    func search(_ query: [Float], profile: SemanticEmbeddingProfile, limit: Int) throws -> [SearchHit] {
        XCTFail("measurement must preserve batch dispatch")
        return []
    }
    func search(_ queries: [[Float]], profile: SemanticEmbeddingProfile, limit: Int) throws -> [[SearchHit]] {
        batchCalls += 1
        switch mode {
        case .failed: throw Failure()
        case .cancelled: throw CancellationError()
        case .empty: return queries.map { _ in [] }
        }
    }
}
