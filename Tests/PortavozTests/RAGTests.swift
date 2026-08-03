import Foundation
import PortavozCore
import XCTest

@testable import ApplicationKit
@testable import IntelligenceKit
@testable import StorageKit

final class RAGFusionTests: XCTestCase {
    func testItemsFoundByBothListsClimb() {
        let fused = RAGFusion.fuse(
            lexical: ["a", "b", "c"],
            semantic: ["c", "d"],
            limit: 10)
        XCTAssertEqual(fused.first, "c", "double-sourced item must win")
        XCTAssertEqual(Set(fused), ["a", "b", "c", "d"])
    }

    func testLimitAndSingleListBehaviour() {
        let fused = RAGFusion.fuse(lexical: ["a", "b", "c"], semantic: [], limit: 2)
        XCTAssertEqual(fused, ["a", "b"], "single-list order preserved, limit honored")
        XCTAssertTrue(RAGFusion.fuse(lexical: [String](), semantic: [], limit: 5).isEmpty)
    }
}

final class LexicalRAGCandidateTests: XCTestCase {
    func testTermLevelFusionRewardsCrossTermEvidenceWithoutDuplicates() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Plan conjunto", startedAt: Date())
        try await store.save(meeting)

        let relevant = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "presupuesto proyecto plan conjunto",
            startTime: 0,
            endTime: 1,
            isFinal: true)
        let budgetPrefix = Array(repeating: "presupuesto", count: 8).joined(separator: " ")
        var budgetOnly: [TranscriptSegment] = []
        budgetOnly.reserveCapacity(20)
        for index in 0..<20 {
            budgetOnly.append(TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "\(budgetPrefix) detalle \(index)",
                startTime: Double(index + 1),
                endTime: Double(index + 2),
                isFinal: true))
        }
        let projectPrefix = Array(repeating: "proyecto", count: 8).joined(separator: " ")
        var projectOnly: [TranscriptSegment] = []
        projectOnly.reserveCapacity(20)
        for index in 0..<20 {
            projectOnly.append(TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "\(projectPrefix) contexto \(index)",
                startTime: Double(index + 21),
                endTime: Double(index + 22),
                isFinal: true))
        }
        try await store.save([relevant] + budgetOnly + projectOnly)

        let hits = try await LocalAskMeetingRetrieval.retrieveLexical(
            queries: [
                "¿Qué acordamos sobre presupuesto y proyecto?",
                "PRESUPUESTO proyecto",
            ],
            store: store,
            limit: 12)

        XCTAssertEqual(hits.first?.segmentID, relevant.id)
        XCTAssertEqual(hits.first?.text, relevant.text)
        XCTAssertEqual(Set(hits.map(\.segmentID)).count, hits.count)
        XCTAssertEqual(hits.count, 12)
    }

    func testLongQuestionFallbackKeepsLateTermsRetrievable() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Long query", startedAt: Date())
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "ninthword decisive context",
            startTime: 0,
            endTime: 1,
            isFinal: true)
        try await store.save(meeting)
        try await store.save([segment])

        let hits = try await LocalAskMeetingRetrieval.retrieveLexical(
            queries: [
                "alpha bravo charlie delta echoo foxtrot golfxx hotelx ninthword",
            ],
            store: store,
            limit: 6)

        XCTAssertEqual(hits.map(\.segmentID), [segment.id])
    }
}

final class SemanticStoreTests: XCTestCase {
    private var store: MeetingStore!
    private var meeting: Meeting!

    override func setUpWithError() throws {
        store = try MeetingStore.inMemory()
        meeting = Meeting(title: "Sync de presupuesto", startedAt: Date())
    }

    private func seed(_ texts: [String]) async throws -> [TranscriptSegment] {
        try await store.save(meeting)
        let segments = texts.enumerated().map { index, text in
            TranscriptSegment(
                meetingID: meeting.id, channel: .system, text: text,
                startTime: Double(index * 10), endTime: Double(index * 10 + 5), isFinal: true)
        }
        try await store.save(segments)
        return segments
    }

    func testEmbeddingLifecycle() async throws {
        let segments = try await seed(["hablamos del deploy", "el gato duerme"])

        let missing = try await store.segmentsNeedingEmbeddings()
        XCTAssertEqual(missing.count, 2)

        // Synthetic normalized vectors: deploy ~ (1,0), gato ~ (0,1).
        let publication = try await store.storeEmbeddings([
            segments[0].id: [1, 0],
            segments[1].id: [0, 1],
        ], for: missing)
        XCTAssertEqual(publication.publishedSegmentIDs, Set(segments.map(\.id)))
        XCTAssertTrue(publication.skippedSegmentIDs.isEmpty)
        let remaining = try await store.segmentsNeedingEmbeddings()
        XCTAssertTrue(remaining.isEmpty)

        // Query near "deploy" retrieves it first.
        let hits = try await store.searchSemantic([0.9, 0.1], limit: 2)
        XCTAssertEqual(hits.first?.snippet, "hablamos del deploy")
        XCTAssertEqual(hits.count, 2)

        // Re-saving the same text preserves the embedding…
        try await store.save([segments[0]])
        let afterResave = try await store.segmentsNeedingEmbeddings()
        XCTAssertTrue(afterResave.isEmpty)

        // …but changed text invalidates it.
        var edited = segments[0]
        edited.text = "hablamos del rollback"
        try await store.save([edited])
        let invalidated = try await store.segmentsNeedingEmbeddings()
        XCTAssertEqual(invalidated.map(\.id), [segments[0].id])
    }

    func testExactSemanticSearchCarriesProfileLocalSimilarityOnly() async throws {
        let segments = try await seed([
            "launch plan",
            "archive context",
        ])
        let candidates = try await store.segmentsNeedingEmbeddings()
        _ = try await store.storeEmbeddings(
            [
                segments[0].id: [1, 0],
                segments[1].id: [0.6, 0.8],
            ],
            for: candidates)

        let semanticHits = try await store.searchSemantic([1, 0], limit: 2)
        let lexicalHits = try await store.search("archive")

        XCTAssertEqual(semanticHits.map(\.segmentID), segments.map(\.id))
        XCTAssertEqual(
            try XCTUnwrap(semanticHits[0].semanticSimilarity),
            1,
            accuracy: 0.000_001)
        XCTAssertEqual(
            try XCTUnwrap(semanticHits[1].semanticSimilarity),
            0.6,
            accuracy: 0.000_001)
        XCTAssertNil(lexicalHits.first?.semanticSimilarity)
    }

    func testProfileFenceKeepsExactSearchAvailableDuringSemanticRebuild() async throws {
        let segments = try await seed([
            "The launch budget remains approved for the autumn release.",
        ])
        let firstProfile = semanticTestProfile(modelRevision: 1)
        let secondProfile = semanticTestProfile(modelRevision: 2)
        let candidates = try await store.segmentsNeedingEmbeddings()
        _ = try await store.storeEmbeddings(
            [segments[0].id: [1, 0]],
            for: candidates,
            profile: firstProfile)
        let firstNeedsMaintenance = try await store.semanticIndexRequiresMaintenance(
            for: firstProfile)
        let secondNeedsMaintenance = try await store.semanticIndexRequiresMaintenance(
            for: secondProfile)
        let firstHits = try await store.searchSemantic(
            [1, 0],
            profile: firstProfile)
        let secondHits = try await store.searchSemantic(
            [1, 0],
            profile: secondProfile)

        XCTAssertFalse(firstNeedsMaintenance)
        XCTAssertTrue(secondNeedsMaintenance)
        XCTAssertEqual(firstHits.map(\.segmentID), [segments[0].id])
        XCTAssertTrue(secondHits.isEmpty)

        let invalidated = try await store.invalidateSemanticEmbeddings(
            incompatibleWith: secondProfile)
        let pending = try await store.segmentsNeedingEmbeddings()
        let exactHits = try await store.search("autumn release")

        XCTAssertEqual(invalidated, 1)
        XCTAssertEqual(pending.map(\.id), [segments[0].id])
        XCTAssertEqual(exactHits.map(\.segmentID), [segments[0].id])
    }

    func testPublicationRejectsWrongDimensionsAndNonFiniteVectors() async throws {
        _ = try await seed([
            "A valid semantic source requires finite vectors in the declared dimension.",
        ])
        let candidates = try await store.segmentsNeedingEmbeddings()
        let candidate = try XCTUnwrap(candidates.first)
        let profile = semanticTestProfile(dimension: 2)

        for invalidVector: [Float] in [[1], [.nan, 0], [.infinity, 0]] {
            do {
                _ = try await store.storeEmbeddings(
                    [candidate.id: invalidVector],
                    for: [candidate],
                    profile: profile)
                XCTFail("Expected invalid semantic vector")
            } catch {
                guard case StorageError.invalidSemanticEmbedding = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        let pending = try await store.segmentsNeedingEmbeddings()
        XCTAssertEqual(pending.count, 1)
    }

    func testEmbeddingPublicationCannotOverwriteAnEditedCandidate() async throws {
        let segments = try await seed([
            "The original rollout remains scheduled for Friday afternoon.",
        ])
        let initialCandidates = try await store.segmentsNeedingEmbeddings()
        let candidate = try XCTUnwrap(initialCandidates.first)
        var edited = segments[0]
        edited.text = "The corrected rollout is now scheduled for Monday morning."
        try await store.save([edited])

        let publication = try await store.storeEmbeddings(
            [candidate.id: [1, 0]],
            for: [candidate])

        XCTAssertTrue(publication.publishedSegmentIDs.isEmpty)
        XCTAssertEqual(publication.skippedSegmentIDs, [candidate.id])
        let pending = try await store.segmentsNeedingEmbeddings()
        XCTAssertEqual(pending.map(\.id), [edited.id])
        XCTAssertEqual(pending.map(\.text), [edited.text])
        let semanticHits = try await store.searchSemantic([1, 0])
        XCTAssertTrue(semanticHits.isEmpty)
    }

    func testEmbeddingPublicationCannotCrossATranscriptRevision() async throws {
        let segments = try await seed([
            "The original transcript carries one stable semantic source.",
        ])
        let initialCandidates = try await store.segmentsNeedingEmbeddings()
        let candidate = try XCTUnwrap(initialCandidates.first)
        var revised = segments[0]
        revised.text = "The reviewed transcript replaces the semantic source safely."
        try await store.applyRefinedCast(
            for: meeting.id,
            expectedTranscriptRevision: 0,
            language: "en",
            speakers: [],
            segments: [revised])

        let publication = try await store.storeEmbeddings(
            [candidate.id: [1, 0]],
            for: [candidate])

        XCTAssertTrue(publication.publishedSegmentIDs.isEmpty)
        XCTAssertEqual(publication.skippedSegmentIDs, [candidate.id])
        let pending = try await store.segmentsNeedingEmbeddings()
        XCTAssertEqual(pending.map(\.transcriptRevision), [1])
        XCTAssertEqual(pending.map(\.text), [revised.text])
        let semanticHits = try await store.searchSemantic([1, 0])
        XCTAssertTrue(semanticHits.isEmpty)
    }

    func testEmbeddingPublicationCannotReviveATombstonedMeeting() async throws {
        _ = try await seed([
            "This semantic source must disappear with its deleted meeting.",
        ])
        let initialCandidates = try await store.segmentsNeedingEmbeddings()
        let candidate = try XCTUnwrap(initialCandidates.first)
        try await store.delete(meeting.id)

        let publication = try await store.storeEmbeddings(
            [candidate.id: [1, 0]],
            for: [candidate])

        XCTAssertTrue(publication.publishedSegmentIDs.isEmpty)
        XCTAssertEqual(publication.skippedSegmentIDs, [candidate.id])
        let pending = try await store.segmentsNeedingEmbeddings()
        let semanticHits = try await store.searchSemantic([1, 0])
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(semanticHits.isEmpty)
    }

    func testTombstonedMeetingsLeaveTheSemanticIndex() async throws {
        let segments = try await seed(["contenido secreto"])
        try await publish([segments[0].id: [1, 0]])
        try await store.delete(meeting.id)

        let hits = try await store.searchSemantic([1, 0], limit: 5)
        XCTAssertTrue(hits.isEmpty)
        let pending = try await store.segmentsNeedingEmbeddings()
        XCTAssertTrue(pending.isEmpty)
    }

    func testProductionWidthSemanticRankingKeepsTopK() async throws {
        let segments = try await seed((0..<18).map {
            "complete semantic passage \($0) with enough source context"
        })
        let dimension = 512
        let embeddings = Dictionary(uniqueKeysWithValues:
            segments.enumerated().map { index, segment -> (UUID, [Float]) in
                let similarity = Float(segments.count - index) / Float(segments.count)
                var vector = [Float](repeating: 0, count: dimension)
                vector[0] = similarity
                vector[1] = sqrt(1 - similarity * similarity)
                return (segment.id, vector)
            })
        try await publish(embeddings)

        var query = [Float](repeating: 0, count: dimension)
        query[0] = 1
        let hits = try await store.searchSemantic(query, limit: 5)

        XCTAssertEqual(hits.count, 5)
        XCTAssertEqual(hits.first?.segmentID, segments[0].id)
        XCTAssertEqual(hits.first?.text, segments[0].text)
        XCTAssertFalse(hits.contains { $0.segmentID == segments.last?.id })
    }

    func testProductionWidthSemanticRankingMatchesScalarReference() async throws {
        let segments = try await seed((0..<257).map { "deterministic semantic passage \($0)" })
        let dimension = 512
        let query = Self.normalizedVector(seed: 0xC0FFEE, dimension: dimension)
        let vectors = (0..<segments.count).map {
            Self.normalizedVector(seed: UInt64($0 + 1), dimension: dimension)
        }
        try await publish(Dictionary(uniqueKeysWithValues:
            zip(segments, vectors).map { ($0.id, $1) }))

        var reference: [(order: Int, id: UUID, score: Float)] = []
        for (order, segment) in segments.enumerated() {
            var score: Float = 0
            for index in query.indices { score += vectors[order][index] * query[index] }
            reference.append((order, segment.id, score))
        }
        reference.sort { left, right in
            left.score > right.score
                || (left.score == right.score && left.order < right.order)
        }
        let expected = reference.prefix(17).map(\.id)

        let hits = try await store.searchSemantic(query, limit: 17)

        XCTAssertEqual(hits.map(\.segmentID), expected)
    }

    func testSemanticRankingBreaksTiesByTraversalAndRejectsNonPositiveLimits() async throws {
        let segments = try await seed((0..<4).map { "equal semantic passage \($0)" })
        try await publish(Dictionary(uniqueKeysWithValues:
            segments.map { ($0.id, [Float](arrayLiteral: 1, 0)) }))

        let hits = try await store.searchSemantic([1, 0], limit: 2)
        let zeroLimit = try await store.searchSemantic([1, 0], limit: 0)
        let negativeLimit = try await store.searchSemantic([1, 0], limit: -1)
        let emptyQuery = try await store.searchSemantic([], limit: 2)

        XCTAssertEqual(hits.map(\.segmentID), Array(segments.prefix(2).map(\.id)))
        XCTAssertTrue(zeroLimit.isEmpty)
        XCTAssertTrue(negativeLimit.isEmpty)
        XCTAssertTrue(emptyQuery.isEmpty)
    }

    func testSemanticRankingMaterializesLargeLimitsInBoundedQueries() async throws {
        let segments = try await seed((0..<501).map { "large semantic result \($0)" })
        let embeddings = Dictionary(uniqueKeysWithValues:
            segments.enumerated().map { index, segment -> (UUID, [Float]) in
                let score = Float(index + 1) / Float(segments.count)
                return (segment.id, [score, sqrt(1 - score * score)])
            })
        try await publish(embeddings)

        let hits = try await store.searchSemantic([1, 0], limit: segments.count)

        XCTAssertEqual(hits.count, segments.count)
        XCTAssertEqual(hits.first?.segmentID, segments.last?.id)
        XCTAssertEqual(hits.last?.segmentID, segments.first?.id)
    }

    func testBlobRoundTrip() {
        let vector: [Float] = [0.25, -1, 3.5, .pi]
        XCTAssertEqual(MeetingStore.floats(from: MeetingStore.blob(from: vector)), vector)
    }

    private func publish(_ embeddings: [UUID: [Float]]) async throws {
        let candidates = try await store.segmentsNeedingEmbeddings().filter {
            embeddings[$0.id] != nil
        }
        _ = try await store.storeEmbeddings(embeddings, for: candidates)
    }

    private static func normalizedVector(seed: UInt64, dimension: Int) -> [Float] {
        var state = seed
        var vector = [Float](repeating: 0, count: dimension)
        var normSquared: Float = 0
        for index in vector.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let value = Float(state >> 40) / Float(1 << 24) * 2 - 1
            vector[index] = value
            normSquared += value * value
        }
        let norm = sqrt(normSquared)
        for index in vector.indices { vector[index] /= norm }
        return vector
    }
}

/// Gated: needs the OS to have (or fetch) the Latin contextual embedding
/// assets — normally preinstalled alongside Apple Intelligence.
final class SentenceEmbedderIntegrationTests: XCTestCase {
    func testBilingualSemanticNeighborhood() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PORTAVOZ_MODEL_TESTS"] == "1",
            "set PORTAVOZ_MODEL_TESTS=1 to run")
        let embedder = try SentenceEmbedder()
        do {
            try await embedder.prepare()
        } catch {
            throw XCTSkip("embedding assets unavailable: \(error)")
        }

        let vectors = try await embedder.embed([
            "we agreed to increase the transcription budget",
            "acordamos subir el presupuesto de transcripción",
            "my cat sleeps all day long",
        ])
        XCTAssertEqual(vectors.count, 3)
        XCTAssertGreaterThan(vectors[0].count, 100)

        func dot(_ a: [Float], _ b: [Float]) -> Float {
            zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        }
        // Cross-lingual paraphrase must sit closer than an unrelated topic.
        XCTAssertGreaterThan(
            dot(vectors[0], vectors[1]), dot(vectors[0], vectors[2]),
            "es/en paraphrase should beat unrelated text")
    }
}
