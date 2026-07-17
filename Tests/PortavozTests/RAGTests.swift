import Foundation
import PortavozCore
import XCTest

@testable import IntelligenceKit
@testable import IntegrationsKit
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

        let hits = try await AskPipeline.retrieveLexical(
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

        let hits = try await AskPipeline.retrieveLexical(
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

    func testBlobRoundTrip() {
        let vector: [Float] = [0.25, -1, 3.5, .pi]
        XCTAssertEqual(MeetingStore.floats(from: MeetingStore.blob(from: vector)), vector)
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
