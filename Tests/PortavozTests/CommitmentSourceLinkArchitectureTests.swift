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

    private static func contents(of relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }
}
