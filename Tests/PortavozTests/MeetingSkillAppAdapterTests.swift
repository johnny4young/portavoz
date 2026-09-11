import ApplicationKit
import Foundation
import IntegrationsKit
import PortavozCore
import XCTest

@testable import portavoz_app

final class MeetingSkillAppAdapterTests: XCTestCase {
    func testGitHubIssueTransportIsEphemeralAndBounded() {
        let configuration = AppGitHubIssueNetworkPolicy.makeSession().configuration

        XCTAssertEqual(
            configuration.timeoutIntervalForRequest,
            AppGitHubIssueNetworkPolicy.requestTimeout)
        XCTAssertEqual(
            configuration.timeoutIntervalForResource,
            AppGitHubIssueNetworkPolicy.resourceTimeout)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(
            configuration.requestCachePolicy,
            .reloadIgnoringLocalAndRemoteCacheData)
    }

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

    @MainActor
    func testSecretGistUsesExactPreviewAndOneDurableEgressFence() async throws {
        let services = try AppServices(arguments: [
            "portavoz-app", "-use-temp-store"
        ])
        let meeting = Meeting(
            title: "Platform Sync / Q3",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_300),
            language: "es")
        let speaker = Speaker(
            meetingID: meeting.id,
            label: "S1",
            displayName: "Ana")
        try await services.store.save(meeting)
        try await services.store.save([speaker])
        try await services.store.save([
            TranscriptSegment(
                meetingID: meeting.id,
                speakerID: speaker.id,
                channel: .system,
                text: "El rollout queda para el viernes.",
                startTime: 0,
                endTime: 3,
                isFinal: true)
        ])
        _ = try await services.store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: "general",
            language: "es",
            markdown: "## Decisiones\n\n- Publicar el viernes.",
            actionItems: []))
        let offer = MeetingSkillOffer(
            kind: .secretGistPublish,
            meetingID: meeting.id)

        let preview = try await services.meetingDetailSkillPreview(
            offer,
            destination: nil)
        guard case .secretGist(let draft) = preview else {
            return XCTFail("the proposal must expose the exact Gist request")
        }
        XCTAssertEqual(draft.description, meeting.title)
        XCTAssertEqual(draft.filename, "platform-sync-q3.md")
        XCTAssertTrue(draft.markdown.contains(meeting.title))
        XCTAssertTrue(draft.markdown.contains("El rollout queda para el viernes."))
        let proposalID = UUID()
        let proposedAt = Date()

        let first = try await services.performMeetingDetailSkill(
            offer,
            proposalID: proposalID,
            proposedAt: proposedAt,
            preview: preview,
            destination: nil)
        XCTAssertEqual(
            first,
            .succeeded(outputURL: URL(
                string: "https://gist.github.com/portavoz/skill-preview")))

        // A repeated UI action finds the settled Skill and does not ask the
        // disposable gateway to record or transport a second publication.
        let replay = try await services.performMeetingDetailSkill(
            offer,
            proposalID: proposalID,
            proposedAt: proposedAt,
            preview: preview,
            destination: nil)
        XCTAssertEqual(replay, .succeeded(outputURL: nil))
        let egress = try await services.store.dataEgressEvents(for: meeting.id)
        XCTAssertEqual(egress.count, 1)
        XCTAssertEqual(egress.first?.id.rawValue, proposalID)
        XCTAssertEqual(egress.first?.operation, .publishGitHubGist)
        XCTAssertEqual(egress.first?.destinationHost, "api.github.com")
    }

    @MainActor
    func testChangedSecretGistPreviewIsRefusedBeforeClaimOrEgress() async throws {
        let services = try AppServices(arguments: [
            "portavoz-app", "-use-temp-store"
        ])
        let meeting = Meeting(
            title: "Platform Sync",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await services.store.save(meeting)
        try await services.store.save([
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .microphone,
                text: "Approved text.",
                startTime: 0,
                endTime: 1,
                isFinal: true)
        ])
        _ = try await services.store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: "general",
            language: "en",
            markdown: "Approved summary.",
            actionItems: []))
        let offer = MeetingSkillOffer(
            kind: .secretGistPublish,
            meetingID: meeting.id)
        let approved = try await services.meetingDetailSkillPreview(
            offer,
            destination: nil)
        guard case .secretGist(let draft) = approved else {
            return XCTFail("expected Gist preview")
        }
        let changed = MeetingSkillPreview.secretGist(SecretGistDraft(
            meetingID: draft.meetingID,
            markdown: draft.markdown + "\nInjected after preview.",
            filename: draft.filename,
            description: draft.description))

        let result = try await services.performMeetingDetailSkill(
            offer,
            proposalID: UUID(),
            proposedAt: Date(),
            preview: changed,
            destination: nil)

        guard case .retryableFailure = result else {
            return XCTFail("changed material must require a fresh proposal")
        }
        let executions = try await services.store.skillExecutions(
            idempotencyKeyPrefix: SecretGistPublishSkill.idempotencyKey(
                for: meeting.id))
        XCTAssertTrue(executions.isEmpty)
        let egress = try await services.store.dataEgressEvents(for: meeting.id)
        XCTAssertTrue(egress.isEmpty)
    }

    func testSecretGistPublisherMarksAnAmbiguousAttemptWithoutAResponseURL() async {
        let publisher = AppSecretGistSkillPublisher(
            documents: FailingGistDocumentPublisher())
        let draft = SecretGistDraft(
            meetingID: MeetingID(),
            markdown: "# Approved",
            filename: "approved.md",
            description: "Approved")

        let startedBeforePublish = await publisher.remoteAttemptStarted()
        XCTAssertFalse(startedBeforePublish)
        do {
            _ = try await publisher.publish(draft)
            XCTFail("the transport double must fail")
        } catch {
            XCTAssertEqual(error as? SecretGistPublishError, .outcomeUnknown)
        }
        let startedAfterFailure = await publisher.remoteAttemptStarted()
        let outputURL = await publisher.outputURL()
        XCTAssertTrue(startedAfterFailure)
        XCTAssertNil(outputURL)
    }

    @MainActor
    func testGitHubIssueUsesExactPreviewAndOneDurableEgressFence() async throws {
        let services = try AppServices(arguments: [
            "portavoz-app", "-use-temp-store"
        ])
        let fixture = try await saveGitHubIssueMeeting(in: services)
        let request = PrepareGitHubIssueDraftRequest(
            meetingID: fixture.meeting.id,
            actionItemID: fixture.item.id,
            repository: "portavoz/demo")
        let draft = try await services.prepareMeetingDetailGitHubIssueDraft(request)
        XCTAssertEqual(draft.title, fixture.item.text)
        XCTAssertTrue(draft.body.contains(fixture.segment.text))
        let proposalID = UUID()
        let proposedAt = Date()

        let first = try await services.performMeetingDetailGitHubIssue(
            draft,
            proposalID: proposalID,
            proposedAt: proposedAt)
        XCTAssertEqual(
            first,
            .succeeded(outputURL: URL(
                string: "https://github.com/portavoz/demo/issues/42")))

        let replay = try await services.performMeetingDetailGitHubIssue(
            draft,
            proposalID: UUID(),
            proposedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(replay, .succeeded(outputURL: nil))
        let egress = try await services.store.dataEgressEvents(for: fixture.meeting.id)
        XCTAssertEqual(egress.count, 1)
        XCTAssertEqual(egress.first?.id.rawValue, proposalID)
        XCTAssertEqual(egress.first?.operation, .createGitHubIssue)
        XCTAssertEqual(egress.first?.destinationHost, "api.github.com")
        let records = try await services.store.skillExecutions(
            idempotencyKeyPrefix: "\(GitHubIssueCreateSkill.id):")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.state, .succeeded)
    }

    @MainActor
    func testChangedGitHubIssueDraftIsRefusedBeforeClaimOrEgress() async throws {
        let services = try AppServices(arguments: [
            "portavoz-app", "-use-temp-store"
        ])
        let fixture = try await saveGitHubIssueMeeting(in: services)
        let approved = try await services.prepareMeetingDetailGitHubIssueDraft(
            PrepareGitHubIssueDraftRequest(
                meetingID: fixture.meeting.id,
                actionItemID: fixture.item.id,
                repository: "portavoz/demo"))
        let changed = GitHubIssueDraft(
            meetingID: approved.meetingID,
            actionItemID: approved.actionItemID,
            repository: approved.repository,
            title: approved.title,
            body: approved.body + "\nInjected after preview.",
            citations: approved.citations)

        let result = try await services.performMeetingDetailGitHubIssue(
            changed,
            proposalID: UUID(),
            proposedAt: Date())
        guard case .retryableFailure = result else {
            return XCTFail("changed material must require a fresh preview")
        }
        let executions = try await services.store.skillExecutions(
            idempotencyKeyPrefix: "\(GitHubIssueCreateSkill.id):")
        XCTAssertTrue(executions.isEmpty)
        let egress = try await services.store.dataEgressEvents(for: fixture.meeting.id)
        XCTAssertTrue(egress.isEmpty)
    }

    func testGitHubIssuePublisherMarksAmbiguousAttemptWithoutResponseURL() async throws {
        let repository = try XCTUnwrap(GitHubRepository("portavoz/demo"))
        let publisher = AppGitHubIssueSkillPublisher(
            repository: repository,
            disposableToken: "token",
            gateway: FailingGitHubIssueGateway())
        try await publisher.prepare()
        let citation = GitHubIssueCitation(
            segmentID: UUID(),
            timestamp: 3,
            speaker: "Ana",
            excerpt: "Ship Friday.")
        let draft = GitHubIssueDraft(
            meetingID: MeetingID(),
            actionItemID: UUID(),
            repository: repository,
            title: "Ship",
            body: "## Evidence\n\nShip Friday.",
            citations: [citation])

        do {
            _ = try await publisher.publish(draft)
            XCTFail("the transport double must fail")
        } catch {
            XCTAssertEqual(error as? GitHubIssueSkillError, .outcomeUnknown)
        }
        let didStart = await publisher.remoteAttemptStarted()
        let outputURL = await publisher.outputURL()
        XCTAssertTrue(didStart)
        XCTAssertNil(outputURL)
    }

    @MainActor
    private func saveGitHubIssueMeeting(
        in services: AppServices
    ) async throws -> (
        meeting: Meeting,
        item: ActionItem,
        segment: TranscriptSegment
    ) {
        let meeting = Meeting(
            title: "Platform Sync",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            language: "en")
        let speaker = Speaker(
            meetingID: meeting.id,
            label: "S1",
            displayName: "Ana")
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: speaker.id,
            channel: .system,
            text: "The rollout stays on Friday.",
            startTime: 3,
            endTime: 5,
            isFinal: true)
        let item = ActionItem(
            text: "Prepare the rollout",
            ownerSpeakerID: speaker.id)
        try await services.store.save(meeting)
        try await services.store.save([speaker])
        try await services.store.save([segment])
        _ = try await services.store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: "general",
            language: "en",
            markdown: "## Action items",
            actionItems: [item],
            actionItemEvidence: [SummaryActionItemEvidence(
                actionItemID: item.id,
                sourceTranscriptRevision: meeting.transcriptRevision,
                evidenceSegmentIDs: [segment.id])]))
        return (meeting, item, segment)
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

private struct FailingGistDocumentPublisher: MeetingDocumentPublishing {
    func publish(
        meetingID: MeetingID,
        markdown: String,
        filename: String,
        description: String
    ) async throws -> URL {
        throw URLError(.cannotConnectToHost)
    }
}

private struct FailingGitHubIssueGateway: DataEgressGateway {
    func perform(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) async throws -> DataEgressResponse {
        _ = networkRequest
        _ = metadata
        throw URLError(.cannotConnectToHost)
    }
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
