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
        let budgetOnly = (0..<20).map { index in
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: Array(repeating: "presupuesto", count: 8).joined(separator: " ")
                    + " detalle \(index)",
                startTime: Double(index + 1),
                endTime: Double(index + 2),
                isFinal: true)
        }
        let projectOnly = (0..<20).map { index in
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: Array(repeating: "proyecto", count: 8).joined(separator: " ")
                    + " contexto \(index)",
                startTime: Double(index + 21),
                endTime: Double(index + 22),
                isFinal: true)
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
        try await store.storeEmbeddings([
            segments[0].id: [1, 0],
            segments[1].id: [0, 1],
        ])
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

    func testTombstonedMeetingsLeaveTheSemanticIndex() async throws {
        let segments = try await seed(["contenido secreto"])
        try await store.storeEmbeddings([segments[0].id: [1, 0]])
        try await store.delete(meeting.id)

        let hits = try await store.searchSemantic([1, 0], limit: 5)
        XCTAssertTrue(hits.isEmpty)
        let pending = try await store.segmentsNeedingEmbeddings()
        XCTAssertTrue(pending.isEmpty)
    }

    func testProductionWidthSemanticRankingKeepsTopKAndSkipsMalformedVectors() async throws {
        let segments = try await seed((0..<18).map {
            "complete semantic passage \($0) with enough source context"
        })
        let dimension = 512
        let embeddings = Dictionary(uniqueKeysWithValues:
            segments.enumerated().map { index, segment -> (UUID, [Float]) in
                if index == segments.count - 1 {
                    return (segment.id, [1, 0])
                }
                if index == segments.count - 2 {
                    var vector = [Float](repeating: 0, count: dimension)
                    vector[0] = .nan
                    return (segment.id, vector)
                }
                let similarity = Float(segments.count - index) / Float(segments.count)
                var vector = [Float](repeating: 0, count: dimension)
                vector[0] = similarity
                vector[1] = sqrt(1 - similarity * similarity)
                return (segment.id, vector)
            })
        try await store.storeEmbeddings(embeddings)

        var query = [Float](repeating: 0, count: dimension)
        query[0] = 1
        let hits = try await store.searchSemantic(query, limit: 5)

        XCTAssertEqual(hits.count, 5)
        XCTAssertEqual(hits.first?.segmentID, segments[0].id)
        XCTAssertEqual(hits.first?.text, segments[0].text)
        XCTAssertFalse(hits.contains { $0.segmentID == segments.last?.id })
        XCTAssertFalse(hits.contains { $0.segmentID == segments.dropLast().last?.id })
    }

    func testProductionWidthSemanticRankingMatchesScalarReference() async throws {
        let segments = try await seed((0..<257).map { "deterministic semantic passage \($0)" })
        let dimension = 512
        let query = Self.normalizedVector(seed: 0xC0FFEE, dimension: dimension)
        let vectors = (0..<segments.count).map {
            Self.normalizedVector(seed: UInt64($0 + 1), dimension: dimension)
        }
        try await store.storeEmbeddings(Dictionary(uniqueKeysWithValues:
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
        try await store.storeEmbeddings(Dictionary(uniqueKeysWithValues:
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
        try await store.storeEmbeddings(embeddings)

        let hits = try await store.searchSemantic([1, 0], limit: segments.count)

        XCTAssertEqual(hits.count, segments.count)
        XCTAssertEqual(hits.first?.segmentID, segments.last?.id)
        XCTAssertEqual(hits.last?.segmentID, segments.first?.id)
    }

    func testBlobRoundTrip() {
        let vector: [Float] = [0.25, -1, 3.5, .pi]
        XCTAssertEqual(MeetingStore.floats(from: MeetingStore.blob(from: vector)), vector)
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
