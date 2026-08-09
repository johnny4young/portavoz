import ApplicationKit
import Foundation
import IntegrationsKit
import PortavozCore
import XCTest

@testable import portavoz_app

final class MeetingSkillAppAdapterTests: XCTestCase {
    func testConfirmedRecapMaterialReplaysTheExactApprovedPreview() async throws {
        let meeting = Meeting(
            title: "Platform sync",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let summary = SummaryDraft(
            meetingID: meeting.id,
            recipeID: "general",
            language: "en",
            markdown: "## Decisions\n\n- Ship the signed export.",
            actionItems: [])
        let confirmed = AppConfirmedRecapMaterial(source: (
            meeting: meeting,
            speakers: [],
            summary: summary))
        let pasteboard = RecordingRecapPasteboard()
        let effect = RecapDraftEffect(
            material: confirmed,
            delivery: AppRecapPasteboardDelivery(pasteboard: pasteboard))
        let (proposal, _) = MeetingSkillProposalFactory.recapProposal(
            meetingID: meeting.id,
            at: Date())

        try await effect.perform(proposal)

        guard case .recap(let subject, let body) = confirmed.preview else {
            return XCTFail("the captured material must expose a recap preview")
        }
        let written = await pasteboard.strings
        XCTAssertEqual(written, ["\(subject)\n\n\(body)"])
    }

    func testChangedRecapIsRejectedAtTheApprovedPreviewBoundary() {
        let meeting = Meeting(
            title: "Platform sync",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        func source(
            _ decision: String
        ) -> (Meeting, [Speaker], SummaryDraft) {
            (
                meeting: meeting,
                speakers: [],
                summary: SummaryDraft(
                    meetingID: meeting.id,
                    recipeID: "general",
                    language: "en",
                    markdown: "## Decisions\n\n- \(decision)",
                    actionItems: []))
        }
        let approved = AppConfirmedRecapMaterial(
            source: source("Ship Friday.")).preview

        XCTAssertNil(
            AppConfirmedRecapMaterial(
                source: source("Ship Monday."),
                approvedPreview: approved),
            "a changed summary must require a new confirmation")
        XCTAssertNotNil(AppConfirmedRecapMaterial(
            source: source("Ship Friday."),
            approvedPreview: approved))
    }

    func testPasteboardRejectionFailsTheSkillInsteadOfClaimingSuccess() async {
        let delivery = AppRecapPasteboardDelivery(
            pasteboard: RejectingRecapPasteboard())

        do {
            try await delivery.deliver(MeetingRecap(
                subject: "Recap",
                markdown: "Nothing changed.\n"))
            XCTFail("a rejected pasteboard write must fail")
        } catch {
            XCTAssertEqual(
                (error as? CategorizedFailure)?.category,
                .recoverable)
        }
    }
}

private actor RecordingRecapPasteboard: RecapPasteboardWriting {
    private(set) var strings: [String] = []

    func replaceString(_ string: String) -> Bool {
        strings.append(string)
        return true
    }
}

private struct RejectingRecapPasteboard: RecapPasteboardWriting {
    func replaceString(_ string: String) async -> Bool { false }
}
