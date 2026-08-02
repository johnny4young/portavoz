import ApplicationKit
import Foundation
import PortavozCore
import XCTest
@testable import portavoz_cli

final class CommitmentLinkQualityProductBenchmarkTests: XCTestCase {
    func testOptionsDefaultToInstalledAssetsAndRejectAmbiguity() throws {
        let options = try CommitmentLinkQualityBenchmarkOptions(arguments: [
            "--fixture", "/tmp/fixture.json",
            "--output", "/tmp/observations.json"
        ])
        XCTAssertFalse(options.allowAssetDownload)

        let download = try CommitmentLinkQualityBenchmarkOptions(arguments: [
            "--fixture", "/tmp/fixture.json",
            "--output", "/tmp/observations.json",
            "--asset-download", "if-needed"
        ])
        XCTAssertTrue(download.allowAssetDownload)
        XCTAssertThrowsError(try CommitmentLinkQualityBenchmarkOptions(arguments: [
            "--fixture", "/tmp/fixture.json",
            "--fixture", "/tmp/other.json",
            "--output", "/tmp/observations.json"
        ])) { error in
            XCTAssertEqual(
                error as? CommitmentLinkQualityBenchmarkError,
                .duplicateOption("--fixture"))
        }
        XCTAssertThrowsError(try CommitmentLinkQualityBenchmarkOptions(arguments: [
            "--fixture", "/tmp/fixture.json",
            "--output", "/tmp/fixture.json"
        ])) { error in
            XCTAssertEqual(
                error as? CommitmentLinkQualityBenchmarkError,
                .outputMatchesFixture)
        }
    }

    func testCanonicalFixtureDigestMatchesAdapterNeutralAuthority() throws {
        let fixture = try CommitmentLinkQualityFixture.load(
            from: Self.canonicalFixtureURL)

        XCTAssertEqual(fixture.cases.count, 36)
        XCTAssertEqual(
            fixture.fixtureSHA256,
            CommitmentLinkQualityFixture.canonicalDigest)
    }

    func testProductRunnerEmitsOneIsolatedExternalIdentityObservationPerCase() async throws {
        let fixture = try CommitmentLinkQualityFixture.load(
            from: Self.canonicalFixtureURL)
        let profile = SemanticEmbeddingProfile(
            modelIdentifier: "commitment-link-quality-test",
            modelRevision: 1,
            vectorDimension: 2,
            pipelineIdentifier: "constant-test-vector",
            pipelineRevision: 1,
            vectorSchemaVersion: 1)
        let runtime = CommitmentLinkQualityRecordingRuntime(profile: profile)

        let document = try await CommitmentLinkQualityProductBenchmark.run(
            fixture: fixture,
            runtime: runtime)

        XCTAssertEqual(document.fixtureGeneration, "public-synthetic-v1")
        XCTAssertEqual(document.fixtureSHA256, fixture.fixtureSHA256)
        XCTAssertEqual(
            document.adapter,
            "product-accelerate-exact-\(profile.fingerprint.prefix(16))-v1")
        XCTAssertEqual(document.observations.count, fixture.cases.count)
        XCTAssertEqual(
            document.observations.map(\.caseID),
            fixture.cases.map(\.id))
        for (fixtureCase, observation) in zip(
            fixture.cases,
            document.observations
        ) {
            let evidenceIDs = Set(fixtureCase.targets.flatMap { $0.evidence.map(\.id) })
            let targetIDs = Set(fixtureCase.targets.map(\.id))
            XCTAssertTrue(Set(observation.semanticHitSegmentIDs).isSubset(of: evidenceIDs))
            XCTAssertTrue(Set(observation.suggestions.map(\.commitmentID)).isSubset(of: targetIDs))
            XCTAssertTrue(observation.suggestions.allSatisfy {
                Set($0.matchedEvidenceSegmentIDs).isSubset(of: evidenceIDs)
                    && (1...20).contains($0.bestSemanticRank)
            })
        }
        let requests = await runtime.assetDownloadRequests
        XCTAssertEqual(requests.count, fixture.cases.count * 2)
        XCTAssertTrue(requests.allSatisfy { !$0 })
    }

    func testPrivateWriterIncludesNullAssigneeIdentityAndNeverOverwrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "commitment-link-quality-writer-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("observations.json")
        let document = CommitmentLinkQualityObservationDocument(
            fixtureGeneration: "public-synthetic-v1",
            fixtureSHA256: CommitmentLinkQualityFixture.canonicalDigest,
            adapter: "product-accelerate-exact-test-v1",
            observations: [CommitmentLinkQualityCaseObservation(
                caseID: "case-001",
                semanticHitSegmentIDs: [],
                suggestions: [CommitmentLinkSuggestionRow(
                    commitmentID: "target-case-001-a",
                    assignee: CommitmentLinkQualityAssignee(kind: "me", id: nil),
                    matchedEvidenceSegmentIDs: ["evidence-target-case-001-a"],
                    bestSemanticRank: 1)])])

        try CommitmentLinkQualityPrivateJSONWriter.write(document, to: output)

        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions]
                as? NSNumber)
        XCTAssertEqual(mode.intValue, 0o600)
        let rootObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: output))
                as? [String: Any])
        let observations = try XCTUnwrap(
            rootObject["observations"] as? [[String: Any]])
        let suggestions = try XCTUnwrap(
            observations[0]["suggestions"] as? [[String: Any]])
        let assignee = try XCTUnwrap(suggestions[0]["assignee"] as? [String: Any])
        XCTAssertTrue(assignee["id"] is NSNull)
        XCTAssertThrowsError(
            try CommitmentLinkQualityPrivateJSONWriter.write(document, to: output)
        ) { error in
            XCTAssertEqual(
                error as? CommitmentLinkQualityBenchmarkError,
                .outputAlreadyExists)
        }
    }

    private static let canonicalFixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(
            "Fixtures/CommitmentLinkQuality/public-synthetic-v1.json")
}

private actor CommitmentLinkQualityRecordingRuntime: SemanticEmbeddingRuntimeClient {
    let profile: SemanticEmbeddingProfile
    private(set) var assetDownloadRequests: [Bool] = []

    init(profile: SemanticEmbeddingProfile) {
        self.profile = profile
    }

    var hasAvailableAssets: Bool { true }

    func semanticEmbeddingProfile() -> SemanticEmbeddingProfile? { profile }

    func prepare(allowAssetDownload: Bool) {
        assetDownloadRequests.append(allowAssetDownload)
    }

    func withPreparedEmbedding<Result: Sendable>(
        allowAssetDownload: Bool,
        operation: @Sendable (
            _ embedder: any SemanticTextEmbedding
        ) async throws -> Result
    ) async throws -> Result {
        assetDownloadRequests.append(allowAssetDownload)
        return try await operation(
            CommitmentLinkQualityConstantEmbedding(profile: profile))
    }
}

private struct CommitmentLinkQualityConstantEmbedding: SemanticTextEmbedding {
    let profile: SemanticEmbeddingProfile

    func semanticEmbeddingProfile() -> SemanticEmbeddingProfile { profile }

    func vectors(for texts: [String]) -> [[Float]] {
        texts.map { _ in [1, 0] }
    }
}
