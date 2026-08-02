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
        XCTAssertTrue(storage.contains("ROW_NUMBER() OVER"))
        XCTAssertTrue(storage.contains("relatedRowCount"))
        XCTAssertFalse(observation.contains("linkCommitmentSource("))
        XCTAssertFalse(appComposition.contains("ObserveCommitmentLinkSuggestions"))
        XCTAssertTrue(decisions.contains("## D246"))
        XCTAssertTrue(decisions.contains(
            "Observe commitment links through bounded product ports"))
    }

    private static func contents(of relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }
}
