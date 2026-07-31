import ApplicationKit
import Foundation
import StorageKit
import XCTest
@testable import portavoz_cli

final class AskQualityProductionBenchmarkTests: XCTestCase {
    func testOptionsRequireBoundedBuildAndCommitIdentity() throws {
        let options = try AskQualityBenchmarkOptions(arguments: [
            "--fixture", "/tmp/fixture.json",
            "--output", "/tmp/observations.json",
            "--build", "0.8.0+42",
            "--commit", String(repeating: "a", count: 40),
        ])

        XCTAssertEqual(options.build, "0.8.0+42")
        XCTAssertEqual(options.commit, String(repeating: "a", count: 40))
        XCTAssertThrowsError(try AskQualityBenchmarkOptions(arguments: [
            "--fixture", "/tmp/fixture.json",
            "--output", "/tmp/observations.json",
            "--build", "test",
            "--commit", "ABC",
        ])) { error in
            XCTAssertEqual(error as? AskQualityBenchmarkError, .invalidCommit)
        }
        XCTAssertThrowsError(try AskQualityBenchmarkOptions(arguments: [
            "--fixture", "/tmp/fixture.json",
            "--output", "/tmp/observations.json",
            "--build", "test",
            "--commit", String(repeating: "٠", count: 40),
        ])) { error in
            XCTAssertEqual(error as? AskQualityBenchmarkError, .invalidCommit)
        }
    }

    func testFixtureRejectsOverlappingRelevantAndHardNegativeEvidence() {
        let fixture = Self.fixture(hardNegativeSegmentIDs: ["segment-001"])

        XCTAssertThrowsError(try fixture.validate()) { error in
            XCTAssertEqual(
                error as? AskQualityBenchmarkError,
                .invalidFixture("invalid query"))
        }
    }

    func testRealLocalRetrievalEmitsCanonicalRevisionWithoutPretendingToJudgeAnswers() async throws {
        let fixture = Self.fixture()
        let store = try MeetingStore.inMemory()
        let mapping = try await AskQualityCorpusMapping.seed(
            fixture: fixture,
            store: store)
        let retrieval = LocalAskMeetingRetrieval(
            store: store,
            queryExpander: NoExpansion(),
            runtime: FixedRuntime())

        let document = try await AskQualityProductionBenchmark.observe(
            fixture: fixture,
            mapping: mapping,
            retrieval: retrieval,
            build: "test",
            commit: String(repeating: "0", count: 40))

        XCTAssertEqual(document.adapter, "local-hybrid-no-expansion-evidence-v1")
        XCTAssertEqual(document.queries.count, 1)
        let query = try XCTUnwrap(document.queries.first)
        XCTAssertEqual(query.queryID, "query-001")
        XCTAssertEqual(query.hits.count, 1)
        XCTAssertEqual(query.hits[0].segmentID, "segment-001")
        XCTAssertEqual(query.hits[0].meetingID, "meeting-001")
        XCTAssertEqual(query.hits[0].timestampMilliseconds, 1_000)
        XCTAssertEqual(query.hits[0].transcriptRevision, 3)

        let encoded = try JSONEncoder().encode(document)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let queries = try XCTUnwrap(root["queries"] as? [[String: Any]])
        let answer = try XCTUnwrap(queries[0]["answer"] as? [String: Any])
        XCTAssertEqual(answer["outcome"] as? String, "notEvaluated")
        XCTAssertTrue(answer["factuality"] is NSNull)
        XCTAssertTrue(answer["citationCoverage"] is NSNull)
    }

    func testPrivateWriterIsOwnerOnlyNonOverwritingAndPreservesParentMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ask-quality-writer-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("observations.json")
        let document = AskQualityObservationDocument(
            fixtureGeneration: "test-v1",
            adapter: "local-hybrid-no-expansion-evidence-v1",
            build: "test",
            commit: String(repeating: "0", count: 40),
            queries: [])

        try AskQualityPrivateJSONWriter.write(document, to: output)

        let parentMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions]
                as? NSNumber)
        let outputMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions]
                as? NSNumber)
        XCTAssertEqual(parentMode.intValue, 0o755)
        XCTAssertEqual(outputMode.intValue, 0o600)
        XCTAssertThrowsError(
            try AskQualityPrivateJSONWriter.write(document, to: output)
        ) { error in
            XCTAssertEqual(
                error as? AskQualityBenchmarkError,
                .outputAlreadyExists)
        }
    }

    private static func fixture(
        hardNegativeSegmentIDs: [String] = []
    ) -> AskQualityFixture {
        AskQualityFixture(
            schemaVersion: 1,
            kind: "ask-quality-fixture",
            generation: "test-v1",
            contentSource: "public-synthetic-only",
            segments: [AskQualityFixtureSegment(
                id: "segment-001",
                meetingID: "meeting-001",
                meetingTitle: "Synthetic planning",
                timestampMilliseconds: 1_000,
                transcriptRevision: 3,
                language: "en",
                owner: "Mara",
                text: "Mara named atlas-001 as the migration owner for Friday.")],
            queries: [AskQualityFixtureQuery(
                id: "query-001",
                text: "Who owns atlas-001?",
                relationship: "englishToEnglish",
                intent: "name",
                relevant: [AskQualityFixtureRelevant(
                    segmentID: "segment-001",
                    grade: 3,
                    expectedTimestampMilliseconds: 1_000,
                    expectedOwner: "Mara")],
                hardNegativeSegmentIDs: hardNegativeSegmentIDs,
                answerPolicy: "answer")])
    }
}

private struct NoExpansion: AskQueryExpanding {
    func expand(_ question: String) -> [String] { [question] }
}

private struct FixedRuntime: SemanticEmbeddingRuntimeClient {
    var hasAvailableAssets: Bool { get async { true } }

    func prepare(allowAssetDownload _: Bool) async throws {}

    func withPreparedEmbedding<Result: Sendable>(
        allowAssetDownload _: Bool,
        operation: @Sendable (
            _ embedder: any SemanticTextEmbedding
        ) async throws -> Result
    ) async throws -> Result {
        try await operation(FixedEmbedding())
    }
}

private struct FixedEmbedding: SemanticTextEmbedding {
    func vectors(for texts: [String]) -> [[Float]] {
        texts.map { _ in [1, 0] }
    }
}
