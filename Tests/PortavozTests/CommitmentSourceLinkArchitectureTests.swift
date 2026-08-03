import Foundation
import XCTest

final class CommitmentSourceLinkArchitectureTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testCrossMeetingCommitmentLinksRequireExplicitConfirmation() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/CommitmentContinuity.swift")
        let application = try Self.contents(
            of: "Sources/ApplicationKit/ManageMeetingCommitmentInbox.swift")
        let candidateProjection = try Self.contents(
            of: "Sources/ApplicationKit/MeetingCommitmentInbox.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+CommitmentContinuity.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(core.contains("struct CommitmentLinkConfirmation"))
        XCTAssertTrue(application.contains("case link(LinkMeetingCommitmentRequest)"))
        XCTAssertTrue(application.contains("repository.linkCommitmentSource("))
        XCTAssertFalse(candidateProjection.contains("linkCommitmentSource"))

        let linkBody = try XCTUnwrap(
            storage.components(separatedBy: "public func linkCommitmentSource").last?
                .components(separatedBy: "public func applyCommitmentTransition").first)
        XCTAssertTrue(linkBody.contains("current.commitment.status == .confirmed"))
        XCTAssertTrue(linkBody.contains("validateActiveCommitmentSource("))
        XCTAssertTrue(linkBody.contains("generatedActionItemSource("))
        XCTAssertTrue(linkBody.contains("cross-meeting evidence must come from a new meeting"))
        XCTAssertTrue(linkBody.contains("CommitmentSourceRecord(source).insert"))
        XCTAssertTrue(linkBody.contains("CommitmentEvidenceSegmentRecord("))
        XCTAssertFalse(linkBody.contains("CommitmentEventRecord("))
        XCTAssertFalse(linkBody.contains("CommitmentRecord("))
        XCTAssertTrue(decisions.contains("## D243"))
        XCTAssertTrue(decisions.contains(
            "Append cross-meeting commitment evidence only after explicit confirmation"))
    }

    func testSuggestionPolicyRemainsPureBoundedAndNonServing() throws {
        let policy = try Self.contents(
            of: "Sources/PortavozCore/CommitmentLinkSuggestion.swift")
        let candidateProjection = try Self.contents(
            of: "Sources/ApplicationKit/MeetingCommitmentInbox.swift")
        let appComposition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingDetail.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(policy.contains("maximumSemanticHitCount = 20"))
        XCTAssertTrue(policy.contains("maximumTargetCount = 200"))
        XCTAssertTrue(policy.contains("maximumSuggestionCount = 3"))
        XCTAssertTrue(policy.contains("target.commitment.assignee == candidateAssignee"))
        XCTAssertFalse(policy.contains("import ApplicationKit"))
        XCTAssertFalse(policy.contains("import IntelligenceKit"))
        XCTAssertFalse(policy.contains("import StorageKit"))
        XCTAssertFalse(candidateProjection.contains("CommitmentLinkSuggestionPolicy"))
        XCTAssertFalse(appComposition.contains("CommitmentLinkSuggestionPolicy"))
        XCTAssertTrue(decisions.contains("## D244"))
        XCTAssertTrue(decisions.contains(
            "Rank commitment links from exact person and evidence identity only"))
    }

    func testObservationAdapterUsesBoundedReadAndSemanticPortsWithoutServing() throws {
        let observation = try Self.contents(
            of: "Sources/ApplicationKit/ObserveCommitmentLinkSuggestions.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+CommitmentLinkSuggestions.swift")
        let appComposition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingDetail.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(observation.contains("allowAssetDownload: false"))
        XCTAssertTrue(observation.contains("semanticIndex.search("))
        XCTAssertTrue(observation.contains("CommitmentLinkSuggestionPolicy.suggestions("))
        XCTAssertTrue(observation.contains("maximumSemanticHitCount"))
        XCTAssertTrue(observation.contains("maximumTargetCount"))
        XCTAssertTrue(observation.contains("semanticProfileFingerprint"))
        XCTAssertTrue(observation.contains("validatedSemanticHits"))
        XCTAssertTrue(observation.contains("invalidSemanticSimilarity"))
        XCTAssertTrue(storage.contains("ROW_NUMBER() OVER"))
        XCTAssertTrue(storage.contains("relatedRowCount"))
        XCTAssertFalse(observation.contains("linkCommitmentSource("))
        XCTAssertFalse(appComposition.contains("ObserveCommitmentLinkSuggestions"))
        XCTAssertTrue(decisions.contains("## D246"))
        XCTAssertTrue(decisions.contains("## D248"))
        XCTAssertTrue(decisions.contains(
            "Observe commitment links through bounded product ports"))
    }

    func testQualityRunnerUsesScratchProductPathWithoutAppComposition() throws {
        let runner = try Self.contents(
            of: "Sources/portavoz-cli/CLIBenchCommitmentLinkQuality.swift")
        let mapping = try Self.contents(
            of: "Sources/portavoz-cli/CLICommitmentLinkQualityCorpusMapping.swift")
        let application = try Self.contents(
            of: "Sources/ApplicationKit/ObserveCommitmentLinkSuggestions.swift")
        let appComposition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingDetail.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(runner.contains("MeetingStore(databaseURL: database)"))
        XCTAssertTrue(runner.contains("ObserveCommitmentLinkSuggestions("))
        XCTAssertTrue(runner.contains("allowAssetDownload: allowAssetDownload"))
        XCTAssertTrue(mapping.contains("saveSummary(SummaryDraft("))
        XCTAssertTrue(mapping.contains("confirmCommitment("))
        XCTAssertTrue(application.contains("allowAssetDownload: false"))
        XCTAssertFalse(appComposition.contains("ObserveCommitmentLinkSuggestions"))
        XCTAssertTrue(decisions.contains("## D247"))
        XCTAssertTrue(decisions.contains(
            "Measure commitment links through isolated product-path fixtures"))
    }

    func testScoredObservationContractRemainsOwnerOnlyAndNonServing() throws {
        let runner = try Self.contents(
            of: "Sources/portavoz-cli/CLIBenchCommitmentLinkQuality.swift")
        let mapping = try Self.contents(
            of: "Sources/portavoz-cli/CLICommitmentLinkQualityCorpusMapping.swift")
        let validator = try Self.contents(
            of: "scripts/commitment_link_quality.py")
        let appComposition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingDetail.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(runner.contains("commitment-link-similarity-observations"))
        XCTAssertTrue(runner.contains("embeddingProfileFingerprint"))
        XCTAssertTrue(runner.contains("evaluationStatus = \"not-evaluated\""))
        XCTAssertTrue(runner.contains("servingStatus = \"not-approved\""))
        XCTAssertTrue(runner.contains("CLIPrivateJSONWriter.write"))
        XCTAssertTrue(mapping.contains("result.semanticHits.map"))
        XCTAssertTrue(validator.contains("validate_similarity_observations"))
        XCTAssertTrue(validator.contains("math.isfinite(similarity)"))
        XCTAssertTrue(validator.contains("descending similarity"))
        XCTAssertFalse(appComposition.contains("CommitmentLinkSimilarityObservation"))
        XCTAssertTrue(decisions.contains("## D249"))
        XCTAssertTrue(decisions.contains(
            "Version scored commitment-link evidence separately from quality observations"))
    }

    func testPrivateSimilarityCollectorCannotBroadenPublicOrAppComposition() throws {
        let runner = try Self.contents(
            of: "Sources/portavoz-cli/CLIBenchCommitmentLinkQuality.swift")
        let validator = try Self.contents(
            of: "scripts/commitment_link_quality.py")
        let appComposition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingDetail.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(runner.contains("BenchPrivateCommitmentLinkSimilarityCommand"))
        XCTAssertTrue(runner.contains("CommitmentLinkPrivateQualityFixture.load"))
        XCTAssertTrue(runner.contains(
            "commitment-link-private-similarity-observations"))
        XCTAssertTrue(runner.contains(
            "private fixture must be a regular non-symlink mode-0600 file"))
        XCTAssertTrue(runner.contains(
            "try CommitmentLinkQualityFixture.load(from: options.fixture)"))
        XCTAssertTrue(validator.contains(
            "validate_private_similarity_observations"))
        XCTAssertTrue(validator.contains(
            "repository-local {label} must be covered by .gitignore"))
        XCTAssertFalse(appComposition.contains(
            "CommitmentLinkPrivateSimilarityDocument"))
        XCTAssertTrue(decisions.contains("## D252"))
        XCTAssertTrue(decisions.contains(
            "Measure private commitment links without weakening public evidence"))
    }

    func testPrivatePolicyReplayRemainsSeparateAndOutsideAppComposition() throws {
        let validator = try Self.contents(
            of: "scripts/commitment_link_quality.py")
        let makefile = try Self.contents(of: "Makefile")
        let appComposition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingDetail.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(validator.contains(
            "commitment-link-private-similarity-policy-replay"))
        XCTAssertTrue(validator.contains(
            "replay_private_similarity_policies"))
        XCTAssertTrue(validator.contains(
            "validate_private_policy_replay"))
        XCTAssertTrue(makefile.contains(
            "commitment-link-private-similarity-replay"))
        XCTAssertFalse(appComposition.contains(
            "PRIVATE_POLICY_REPLAY_KIND"))
        XCTAssertFalse(appComposition.contains(
            "replay_private_similarity_policies"))
        XCTAssertTrue(decisions.contains("## D253"))
        XCTAssertTrue(decisions.contains(
            "Replay private commitment-link evidence without selecting policy"))
    }

    func testCleanProfileMatrixRemainsReviewOnlyAndOutsideAppComposition() throws {
        let validator = try Self.contents(
            of: "scripts/commitment_link_quality.py")
        let runner = try Self.contents(
            of: "scripts/run-commitment-link-profile-matrix.sh")
        let makefile = try Self.contents(of: "Makefile")
        let appComposition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingDetail.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(validator.contains(
            "commitment-link-public-private-profile-matrix"))
        XCTAssertTrue(validator.contains(
            "compare_public_private_profile"))
        XCTAssertTrue(runner.contains(
            "commitment-link profile matrix requires a clean committed checkout"))
        XCTAssertTrue(runner.contains("--asset-download never"))
        XCTAssertTrue(makefile.contains("commitment-link-profile-matrix"))
        XCTAssertFalse(appComposition.contains("PROFILE_MATRIX_KIND"))
        XCTAssertFalse(appComposition.contains(
            "compare_public_private_profile"))
        XCTAssertTrue(decisions.contains("## D254"))
        XCTAssertTrue(decisions.contains(
            "Compare public and private commitment-link evidence on one clean profile"))
    }

    private static func contents(of relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }
}
