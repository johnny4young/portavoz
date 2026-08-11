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

    func testConfirmedEmailRecapHandsOffTheExactApprovedPreview() async throws {
        let meeting = Meeting(
            title: "Platform sync",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let summary = SummaryDraft(
            meetingID: meeting.id,
            recipeID: "general",
            language: "en",
            markdown: "## Decisions\n\n- Ship the signed export.",
            actionItems: [])
        let confirmed = AppConfirmedEmailRecapMaterial(source: (
            meeting: meeting,
            speakers: [],
            summary: summary))
        let opener = RecordingEmailDraftOpener(accepts: true)
        let effect = EmailRecapDraftEffect(
            material: confirmed,
            delivery: AppEmailRecapDraftDelivery(opener: opener))
        let (proposal, _) = MeetingSkillProposalFactory
            .emailRecapDraftProposal(
                meetingID: meeting.id,
                at: Date())

        try await effect.perform(proposal)

        guard case .emailDraft(let subject, let body) = confirmed.preview else {
            return XCTFail("the captured material must expose an email preview")
        }
        let calls = await opener.calls
        XCTAssertEqual(calls, [EmailDraftOpenCall(
            subject: subject,
            body: body,
        )])
    }

    func testChangedEmailRecapIsRejectedAtItsOwnApprovedPreviewBoundary() {
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
        let approved = AppConfirmedEmailRecapMaterial(
            source: source("Ship Friday.")).preview

        XCTAssertNil(AppConfirmedEmailRecapMaterial(
            source: source("Ship Monday."),
            approvedPreview: approved))
        XCTAssertNotNil(AppConfirmedEmailRecapMaterial(
            source: source("Ship Friday."),
            approvedPreview: approved))
        XCTAssertNil(AppConfirmedEmailRecapMaterial(
            source: source("Ship Friday."),
            approvedPreview: .recap(subject: "wrong surface", body: "body")),
            "clipboard approval cannot authorize an external-app handoff")
    }

    func testEmailComposerRejectionFailsRecoverablyInsteadOfClaimingHandoff() async {
        let opener = RecordingEmailDraftOpener(accepts: false)
        let delivery = AppEmailRecapDraftDelivery(opener: opener)

        do {
            try await delivery.deliver(MeetingRecap(
                subject: "Recap",
                markdown: "Nothing changed.\n"))
            XCTFail("an unavailable email composer must fail")
        } catch {
            XCTAssertEqual(
                (error as? CategorizedFailure)?.category,
                .recoverable)
        }
        let calls = await opener.calls
        XCTAssertEqual(calls.count, 1)
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

private struct EmailDraftOpenCall: Equatable, Sendable {
    let subject: String
    let body: String
}

private actor RecordingEmailDraftOpener: AppEmailDraftOpening {
    private let accepts: Bool
    private(set) var calls: [EmailDraftOpenCall] = []

    init(accepts: Bool) {
        self.accepts = accepts
    }

    func openDraft(subject: String, body: String) -> Bool {
        calls.append(EmailDraftOpenCall(subject: subject, body: body))
        return accepts
    }
}
