import ApplicationKit
import Foundation
import XCTest
@testable import portavoz_cli

final class RetrievalChunkEvidenceBenchmarkTests: XCTestCase {
    func testOptionsRequireEverySourceAndHostIdentityOnce() throws {
        let options = try RetrievalChunkEvidenceOptions(arguments: [
            "--fixture", "/tmp/fixture.json",
            "--output", "/tmp/output.json",
            "--build", "search4b+d353",
            "--commit", String(repeating: "a", count: 40),
            "--fixture-sha256", String(repeating: "b", count: 64),
            "--toolchain-sha256", String(repeating: "c", count: 64),
            "--host-profile", "reference",
            "--retrieval-unit", "semantic-boundary"
        ])

        XCTAssertEqual(options.role, .semanticBoundary)
        XCTAssertEqual(options.hostProfile, "reference")
        XCTAssertThrowsError(try RetrievalChunkEvidenceOptions(arguments: [
            "--fixture", "/tmp/fixture.json",
            "--fixture", "/tmp/other.json"
        ])) { error in
            XCTAssertEqual(
                error as? RetrievalChunkEvidenceError,
                .duplicateOption("--fixture"))
        }
        XCTAssertThrowsError(try RetrievalChunkEvidenceOptions(arguments: [
            "--fixture", "/tmp/fixture.json",
            "--output", "/tmp/output.json",
            "--build", "test",
            "--commit", String(repeating: "A", count: 40)
        ])) { error in
            XCTAssertEqual(
                error as? RetrievalChunkEvidenceError,
                .invalidIdentity("--commit"))
        }
    }

    func testEveryCandidateRetainsFenceOnlyAndEquivalentTextCorrections() async throws {
        let fixture = try AskQualityFixture.load(from: Self.fixtureURL)
        let meetings = try RetrievalChunkEvidenceCorpus.meetings(from: fixture)
        let meeting = try XCTUnwrap(meetings.first)
        let embedding = RetrievalChunkEvidenceEmbedding()

        for role in RetrievalChunkEvidenceRole.allCases {
            let baseline = try await RetrievalChunkEvidenceCorpus.projection(
                for: meeting,
                role: role,
                embedding: embedding)
            for scenario in [
                RetrievalChunkCorrectionScenario.publicationFences,
                .normalizedEquivalentText
            ] {
                let corrected = try RetrievalChunkEvidenceCorpus.corrected(
                    meeting,
                    scenario: scenario)
                let current = try await RetrievalChunkEvidenceCorpus.projection(
                    for: corrected,
                    role: role,
                    embedding: embedding)
                let delta = RetrievalChunkEvidenceDelta.between(
                    previous: baseline,
                    current: current)

                XCTAssertEqual(delta.upsertCount, 0, "\(role) \(scenario)")
                XCTAssertEqual(delta.removedCount, 0, "\(role) \(scenario)")
                XCTAssertEqual(
                    delta.retainedCount,
                    baseline.units.count,
                    "\(role) \(scenario)")
            }
        }
    }

    func testSemanticObservationIsContentFreeAndLeavesDecisionsOpen() async throws {
        let fixture = try AskQualityFixture.load(from: Self.fixtureURL)
        let options = try RetrievalChunkEvidenceOptions(arguments: [
            "--fixture", Self.fixtureURL.path,
            "--output", "/tmp/retrieval-chunk-evidence.json",
            "--build", "test",
            "--commit", String(repeating: "a", count: 40),
            "--fixture-sha256", String(repeating: "b", count: 64),
            "--toolchain-sha256", String(repeating: "c", count: 64),
            "--host-profile", "test-host",
            "--retrieval-unit", "semantic-boundary"
        ])

        let observation = try await RetrievalChunkEvidenceBenchmark.run(
            fixture: fixture,
            options: options,
            embedding: RetrievalChunkEvidenceEmbedding())

        XCTAssertEqual(observation.authority, "research-resource-correction-only")
        XCTAssertEqual(observation.candidateSelection, "not-evaluated")
        XCTAssertEqual(observation.performanceDecision, "not-evaluated")
        XCTAssertEqual(observation.corrections.count, 7)
        XCTAssertEqual(observation.construction.turnCount, 120)
        XCTAssertEqual(
            observation.construction.diagnostics?.vectorizedTurnCount,
            0,
            "the canonical fixture's mixed-language turns cannot impersonate semantic resource coverage")
        XCTAssertTrue(observation.construction.resources.wallMilliseconds.isFinite)
        XCTAssertGreaterThanOrEqual(
            observation.construction.resources.wallMilliseconds,
            0)

        let data = try JSONEncoder().encode(observation)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains("segment-001"))
        XCTAssertFalse(encoded.contains("atlas-001"))
        XCTAssertFalse(encoded.contains("sourceSegmentIDs"))
        XCTAssertFalse(encoded.contains("meetingID"))
        XCTAssertFalse(encoded.contains("vectorValues"))
    }

    func testSegmentObservationOmitsInapplicableSemanticDiagnostics() async throws {
        let fixture = try AskQualityFixture.load(from: Self.fixtureURL)
        let options = try RetrievalChunkEvidenceOptions(arguments: [
            "--fixture", Self.fixtureURL.path,
            "--output", "/tmp/retrieval-chunk-segment-evidence.json",
            "--build", "test",
            "--commit", String(repeating: "a", count: 40),
            "--fixture-sha256", String(repeating: "b", count: 64),
            "--toolchain-sha256", String(repeating: "c", count: 64),
            "--host-profile", "test-host",
            "--retrieval-unit", "segment"
        ])

        let observation = try await RetrievalChunkEvidenceBenchmark.run(
            fixture: fixture,
            options: options)
        let data = try JSONEncoder().encode(observation)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let construction = try XCTUnwrap(
            document["construction"] as? [String: Any])
        let corrections = try XCTUnwrap(
            document["corrections"] as? [[String: Any]])

        XCTAssertNil(construction["diagnostics"])
        XCTAssertTrue(corrections.allSatisfy { $0["diagnostics"] == nil })
    }

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/AskQuality/public-synthetic-v2.json")
}

private actor RetrievalChunkEvidenceEmbedding:
    RetrievalSemanticBoundaryEmbedding {
    private let english = CLIAppleSentenceBoundaryEmbedding.profile(
        language: "en",
        revision: 1,
        dimension: 2)
    private let spanish = CLIAppleSentenceBoundaryEmbedding.profile(
        language: "es",
        revision: 1,
        dimension: 2)

    func boundaryProposal() -> RetrievalSemanticBoundaryProposal {
        let proposal = CLIAppleSentenceBoundaryEmbedding.proposal(
            englishProfile: english,
            spanishProfile: spanish)
        return RetrievalSemanticBoundaryProposal(
            candidateIdentifier: proposal.candidateIdentifier,
            candidateRevision: proposal.candidateRevision,
            scope: proposal.scope,
            canonicalUnit: proposal.canonicalUnit,
            sourceReuse: proposal.sourceReuse,
            actorTopology: proposal.actorTopology,
            resourceBounds: proposal.resourceBounds,
            boundarySignal: .semanticSimilarity(
                embeddingSpace: .partitionedByLanguage([
                    .init(
                        language: "en",
                        profile: english,
                        minimumCosineSimilarity: -1),
                    .init(
                        language: "es",
                        profile: spanish,
                        minimumCosineSimilarity: -1)
                ])))
    }

    func vector(
        for text: String,
        language: String
    ) throws -> RetrievalSemanticBoundaryVector {
        let profile = language == "en" ? english : spanish
        return RetrievalSemanticBoundaryVector(
            language: language,
            profileFingerprint: profile.fingerprint,
            values: text.count.isMultiple(of: 2) ? [1, 0] : [0.9, 0.1])
    }
}
