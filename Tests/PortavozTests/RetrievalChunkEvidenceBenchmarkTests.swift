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
        let fixture = try RetrievalChunkResourceFixture.load(from: Self.fixtureURL)
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
        let fixture = try RetrievalChunkResourceFixture.load(from: Self.fixtureURL)
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

        let embedding = RetrievalChunkEvidenceEmbedding()
        let observation = try await RetrievalChunkEvidenceBenchmark.run(
            fixture: fixture,
            options: options,
            embedding: embedding)

        XCTAssertEqual(observation.authority, "research-resource-correction-only")
        XCTAssertEqual(observation.candidateSelection, "not-evaluated")
        XCTAssertEqual(observation.performanceDecision, "not-evaluated")
        XCTAssertEqual(observation.corrections.count, 7)
        XCTAssertEqual(observation.schemaVersion, 2)
        XCTAssertEqual(observation.preparation, .bilingualSemantic)
        XCTAssertEqual(observation.corpus.meetingCount, 60)
        XCTAssertEqual(observation.corpus.sourceSegmentCount, 480)
        XCTAssertEqual(observation.corpus.homogeneousEnglishTurnCount, 120)
        XCTAssertEqual(observation.corpus.homogeneousSpanishTurnCount, 120)
        XCTAssertEqual(observation.construction.turnCount, 240)
        XCTAssertEqual(
            observation.construction.diagnostics?.vectorizedTurnCount,
            240,
            "every honestly homogeneous public turn must exercise its language vector path")
        XCTAssertTrue(observation.construction.resources.wallMilliseconds.isFinite)
        XCTAssertGreaterThanOrEqual(
            observation.construction.resources.wallMilliseconds,
            0)
        let calls = await embedding.recordedCalls()
        XCTAssertEqual(Array(calls.prefix(2).map(\.language)), ["en", "es"])
        XCTAssertTrue(calls.prefix(2).allSatisfy {
            !$0.text.contains("resource-")
        })
        let measuredVectorCount = try XCTUnwrap(
            observation.construction.diagnostics?.vectorizedTurnCount)
            + observation.corrections.reduce(0) {
                $0 + ($1.diagnostics?.vectorizedTurnCount ?? 0)
            }
        XCTAssertEqual(calls.count, 2 + measuredVectorCount)

        let data = try JSONEncoder().encode(observation)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains("resource-segment-001-01"))
        XCTAssertFalse(encoded.contains("resource-001"))
        XCTAssertFalse(encoded.contains("sourceSegmentIDs"))
        XCTAssertFalse(encoded.contains("meetingID"))
        XCTAssertFalse(encoded.contains("vectorValues"))
    }

    func testSegmentObservationOmitsInapplicableSemanticDiagnostics() async throws {
        let fixture = try RetrievalChunkResourceFixture.load(from: Self.fixtureURL)
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
        XCTAssertEqual(observation.preparation, .notApplicable)
    }

    func testInvalidSpanishWarmupFailsBeforeFixtureConstruction() async throws {
        let fixture = try RetrievalChunkResourceFixture.load(from: Self.fixtureURL)
        let options = try RetrievalChunkEvidenceOptions(arguments: [
            "--fixture", Self.fixtureURL.path,
            "--output", "/tmp/retrieval-chunk-invalid-warmup.json",
            "--build", "test",
            "--commit", String(repeating: "a", count: 40),
            "--fixture-sha256", String(repeating: "b", count: 64),
            "--toolchain-sha256", String(repeating: "c", count: 64),
            "--host-profile", "test-host",
            "--retrieval-unit", "semantic-boundary"
        ])
        let embedding = RetrievalChunkEvidenceEmbedding(
            invalidWarmupLanguage: "es")

        do {
            _ = try await RetrievalChunkEvidenceBenchmark.run(
                fixture: fixture,
                options: options,
                embedding: embedding)
            XCTFail("invalid bilingual preparation must fail closed")
        } catch {
            XCTAssertEqual(
                error as? RetrievalChunkEvidenceError,
                .semanticEmbeddingUnavailable)
        }
        let callCount = await embedding.recordedCalls().count
        XCTAssertEqual(callCount, 2)
    }

    func testResourceFixturePublishesExactHomogeneousBilingualCoverage() throws {
        let fixture = try RetrievalChunkResourceFixture.load(from: Self.fixtureURL)

        XCTAssertEqual(
            try fixture.coverage(),
            RetrievalChunkResourceFixture.Coverage(
                meetingCount: 60,
                sourceSegmentCount: 480,
                homogeneousEnglishTurnCount: 120,
                homogeneousSpanishTurnCount: 120))
        XCTAssertEqual(fixture.generation, Self.fixtureGeneration)
        XCTAssertEqual(fixture.contentSource, "public-synthetic-only")
    }

    func testResourceFixtureRejectsMixedLanguageCompleteTurn() throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        var segments = try XCTUnwrap(
            document["segments"] as? [[String: Any]])
        segments[1]["language"] = "es"
        document["segments"] = segments
        let mutated = try JSONSerialization.data(withJSONObject: document)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "retrieval-resource-mixed-\(UUID().uuidString).json")
        try mutated.write(to: url, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(
            try RetrievalChunkResourceFixture.load(from: url)
        ) { error in
            XCTAssertEqual(
                error as? RetrievalChunkResourceFixtureError,
                .mixedLanguageTurn)
        }
    }

    func testResourceFixtureRejectsOversizedInputBeforeDecoding() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "retrieval-resource-oversized-\(UUID().uuidString).json")
        try Data(
            repeating: 0x20,
            count: RetrievalChunkResourceFixture.maximumByteCount + 1
        ).write(to: url, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(
            try RetrievalChunkResourceFixture.load(from: url)
        ) { error in
            XCTAssertEqual(
                error as? RetrievalChunkResourceFixtureError,
                .tooLarge)
        }
    }

    private static let fixtureGeneration = "public-bilingual-homogeneous-v1"
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(
            "Fixtures/RetrievalChunkResource/\(fixtureGeneration).json")
}

private actor RetrievalChunkEvidenceEmbedding:
    RetrievalSemanticBoundaryEmbedding {
    struct Call: Sendable {
        let text: String
        let language: String
    }

    private let english = CLIAppleSentenceBoundaryEmbedding.profile(
        language: "en",
        revision: 1,
        dimension: 2)
    private let spanish = CLIAppleSentenceBoundaryEmbedding.profile(
        language: "es",
        revision: 1,
        dimension: 2)
    private let invalidWarmupLanguage: String?
    private var calls: [Call] = []

    init(invalidWarmupLanguage: String? = nil) {
        self.invalidWarmupLanguage = invalidWarmupLanguage
    }

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
        calls.append(Call(text: text, language: language))
        let profile = language == "en" ? english : spanish
        let values: [Float]
        if calls.count <= 2, language == invalidWarmupLanguage {
            values = [0, 0]
        } else {
            values = text.count.isMultiple(of: 2) ? [1, 0] : [0.9, 0.1]
        }
        return RetrievalSemanticBoundaryVector(
            language: language,
            profileFingerprint: profile.fingerprint,
            values: values)
    }

    func recordedCalls() -> [Call] {
        calls
    }
}
