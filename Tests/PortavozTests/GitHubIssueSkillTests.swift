import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class GitHubIssueSkillTests: XCTestCase {
    func testRepositoryAcceptsOnlyCanonicalOwnerAndName() throws {
        XCTAssertEqual(GitHubRepository(" owner/repo ")?.rawValue, "owner/repo")
        XCTAssertEqual(GitHubRepository("Owner/repo.name_2")?.rawValue, "Owner/repo.name_2")

        for invalid in [
            "owner", "owner/repo/extra", "/repo", "owner/", "-owner/repo",
            "owner-/repo", "owner/..", "owner/repo?state=open", "owner/repo#x",
            "owner/repo%2Fevil", "owner name/repo",
        ] {
            XCTAssertNil(GitHubRepository(invalid), invalid)
        }
        XCTAssertNil(GitHubRepository(
            "\(String(repeating: "o", count: GitHubRepository.maximumOwnerLength + 1))/repo"))
        XCTAssertNil(GitHubRepository(
            "owner/\(String(repeating: "r", count: GitHubRepository.maximumNameLength + 1))"))
    }

    func testDraftUsesExactPendingItemOwnerAndCurrentCitation() async throws {
        let fixture = try GitHubIssueFixture()
        let draft = try await fixture.prepare().execute(
            PrepareGitHubIssueDraftRequest(
                meetingID: fixture.meeting.id,
                actionItemID: fixture.actionItem.id,
                repository: "portavoz/demo"))

        XCTAssertEqual(draft.meetingID, fixture.meeting.id)
        XCTAssertEqual(draft.actionItemID, fixture.actionItem.id)
        XCTAssertEqual(draft.repository.rawValue, "portavoz/demo")
        XCTAssertEqual(draft.title, "Prepare the rollout")
        XCTAssertEqual(draft.citations.count, 1)
        XCTAssertEqual(draft.citations.first?.segmentID, fixture.segment.id)
        XCTAssertEqual(draft.citations.first?.timestamp, 3)
        XCTAssertEqual(draft.citations.first?.speaker, "Ana")
        XCTAssertEqual(
            draft.citations.first?.excerpt,
            "The rollout stays on Friday [review](now).")
        XCTAssertTrue(draft.body.contains("Meeting action item from **Platform Sync / Q3**."))
        XCTAssertTrue(draft.body.contains("Agreed owner: **Ana**."))
        XCTAssertTrue(draft.body.contains(
            #"- `00:03` **Ana**: The rollout stays on Friday \[review\]\(now\)."#))
        XCTAssertTrue(draft.isValid)
    }

    func testCorrectedCitationIsUsedOnlyWhenSummaryMatchesCorrectionRevision() async throws {
        let current = try GitHubIssueFixture(correctedText: "Ship on Monday.")
        let draft = try await current.prepare().execute(
            PrepareGitHubIssueDraftRequest(
                meetingID: current.meeting.id,
                actionItemID: current.actionItem.id,
                repository: "portavoz/demo"))
        XCTAssertEqual(draft.citations.map(\.excerpt), ["Ship on Monday."])
        XCTAssertFalse(draft.body.contains("Friday"))

        let stale = try GitHubIssueFixture(
            correctedText: "Ship on Monday.",
            summaryMatchesCorrection: false)
        await XCTAssertThrowsErrorAsync(
            try await stale.prepare().execute(PrepareGitHubIssueDraftRequest(
                meetingID: stale.meeting.id,
                actionItemID: stale.actionItem.id,
                repository: "portavoz/demo")),
            equals: GitHubIssueSkillError.staleSummary)
    }

    func testDraftScaffoldingUsesTheSummaryLanguageInsteadOfTheAppLocale() async throws {
        let fixture = try GitHubIssueFixture(summaryLanguage: "es")

        let draft = try await fixture.prepare().execute(
            PrepareGitHubIssueDraftRequest(
                meetingID: fixture.meeting.id,
                actionItemID: fixture.actionItem.id,
                repository: "portavoz/demo"))

        XCTAssertTrue(draft.body.contains("Tarea de reunión de **Platform Sync / Q3**."))
        XCTAssertTrue(draft.body.contains("Responsable acordado: **Ana**."))
        XCTAssertTrue(draft.body.contains("## Evidencia"))
        XCTAssertTrue(draft.body.contains(
            "_Creado por Portavoz después de una revisión explícita._"))
    }

    func testInvalidRepositoryFailsBeforeReadingMeetingMaterial() async {
        let reader = GitHubIssueReader(detail: nil)
        let prepare = PrepareGitHubIssueDraft(
            library: QueryMeetingLibrary(reader: reader))

        await XCTAssertThrowsErrorAsync(
            try await prepare.execute(PrepareGitHubIssueDraftRequest(
                meetingID: MeetingID(),
                actionItemID: UUID(),
                repository: "owner/repo/extra")),
            equals: GitHubIssueSkillError.invalidRepository)
        let reads = await reader.detailReadCount
        XCTAssertEqual(reads, 0)
    }

    func testMissingDoneOrUncitedItemFailsClosed() async throws {
        let missing = try GitHubIssueFixture()
        await XCTAssertThrowsErrorAsync(
            try await missing.prepare().execute(PrepareGitHubIssueDraftRequest(
                meetingID: missing.meeting.id,
                actionItemID: UUID(),
                repository: "portavoz/demo")),
            equals: GitHubIssueSkillError.actionItemUnavailable)

        let done = try GitHubIssueFixture(itemIsDone: true)
        await XCTAssertThrowsErrorAsync(
            try await done.prepare().execute(PrepareGitHubIssueDraftRequest(
                meetingID: done.meeting.id,
                actionItemID: done.actionItem.id,
                repository: "portavoz/demo")),
            equals: GitHubIssueSkillError.actionItemUnavailable)

        let uncited = try GitHubIssueFixture(includeEvidence: false)
        await XCTAssertThrowsErrorAsync(
            try await uncited.prepare().execute(PrepareGitHubIssueDraftRequest(
                meetingID: uncited.meeting.id,
                actionItemID: uncited.actionItem.id,
                repository: "portavoz/demo")),
            equals: GitHubIssueSkillError.citationsUnavailable)
    }

    func testTooManyCitationsFailInsteadOfSilentlyDroppingEvidence() async throws {
        let fixture = try GitHubIssueFixture(
            evidenceCount: GitHubIssueDraft.maximumCitationCount + 1)
        await XCTAssertThrowsErrorAsync(
            try await fixture.prepare().execute(PrepareGitHubIssueDraftRequest(
                meetingID: fixture.meeting.id,
                actionItemID: fixture.actionItem.id,
                repository: "portavoz/demo")),
            equals: GitHubIssueSkillError.citationsUnavailable)
    }

    func testProposalAndEffectBindExactItemRepositoryAndDraft() async throws {
        let fixture = try GitHubIssueFixture()
        let draft = try await fixture.prepare().execute(
            PrepareGitHubIssueDraftRequest(
                meetingID: fixture.meeting.id,
                actionItemID: fixture.actionItem.id,
                repository: "portavoz/demo"))
        let proposalID = UUID()
        let proposedAt = Date(timeIntervalSince1970: 42)
        let proposal = GitHubIssueCreateSkill.proposal(
            id: proposalID,
            draft: draft,
            proposedAt: proposedAt)
        XCTAssertEqual(proposal.id, proposalID)
        XCTAssertEqual(proposal.definition, GitHubIssueCreateSkill.definition)
        XCTAssertEqual(proposal.subject, .meeting(fixture.meeting.id))
        XCTAssertEqual(proposal.arguments, [
            .meeting(fixture.meeting.id),
            .actionItem(fixture.actionItem.id),
            .text("portavoz/demo"),
        ])
        XCTAssertNotEqual(
            GitHubIssueCreateSkill.idempotencyKey(for: draft),
            GitHubIssueCreateSkill.idempotencyKey(for: GitHubIssueDraft(
                meetingID: draft.meetingID,
                actionItemID: draft.actionItemID,
                repository: try XCTUnwrap(GitHubRepository("portavoz/other")),
                title: draft.title,
                body: draft.body,
                citations: draft.citations)))

        let publisher = GitHubIssuePublisherSpy()
        try await GitHubIssueCreateEffect(
            draft: draft,
            publisher: publisher).perform(proposal)
        let published = await publisher.drafts
        XCTAssertEqual(published, [draft])

        var changedArguments = proposal.arguments
        changedArguments[1] = .actionItem(UUID())
        let forged = SkillProposal(
            id: proposal.id,
            definition: proposal.definition,
            subject: proposal.subject,
            requestedCapabilities: proposal.requestedCapabilities,
            requestedInputDataClasses: proposal.requestedInputDataClasses,
            arguments: changedArguments,
            proposedAt: proposal.proposedAt)
        do {
            try await GitHubIssueCreateEffect(
                draft: draft,
                publisher: publisher).perform(forged)
            XCTFail("changed item identity must not reuse the approved draft")
        } catch let error as GitHubIssueSkillError {
            XCTAssertEqual(error, .invalidDraft)
        }
        let afterForgery = await publisher.drafts
        XCTAssertEqual(afterForgery, [draft])
    }
}

private struct GitHubIssueFixture {
    let meeting: Meeting
    let speaker: Speaker
    let segment: TranscriptSegment
    let actionItem: ActionItem
    let detail: MeetingLibraryDetail

    init(
        itemIsDone: Bool = false,
        includeEvidence: Bool = true,
        evidenceCount: Int = 1,
        correctedText: String? = nil,
        summaryMatchesCorrection: Bool = true,
        summaryLanguage: String = "en"
    ) throws {
        let meeting = Meeting(
            id: MeetingID(rawValue: UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!),
            title: "Platform Sync / Q3",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            language: "en",
            transcriptRevision: 2)
        let speaker = Speaker(
            id: SpeakerID(rawValue: UUID(uuidString: "A1000000-0000-4000-8000-000000000002")!),
            meetingID: meeting.id,
            label: "S1",
            displayName: "Ana")
        let segment = TranscriptSegment(
            id: UUID(uuidString: "A1000000-0000-4000-8000-000000000003")!,
            meetingID: meeting.id,
            speakerID: speaker.id,
            channel: .system,
            text: "The rollout stays on Friday [review](now).",
            language: "en",
            startTime: 3,
            endTime: 7,
            isFinal: true)
        let actionItem = ActionItem(
            id: UUID(uuidString: "A1000000-0000-4000-8000-000000000004")!,
            text: "Prepare the rollout",
            ownerSpeakerID: speaker.id,
            isDone: itemIsDone)
        let additional = (1..<evidenceCount).map { index in
            TranscriptSegment(
                id: UUID(uuidString: String(
                    format: "A1000000-0000-4000-8000-%012d", index + 4))!,
                meetingID: meeting.id,
                speakerID: speaker.id,
                channel: .system,
                text: "Supporting evidence \(index).",
                language: "en",
                startTime: 3 + Double(index),
                endTime: 4 + Double(index),
                isFinal: true)
        }
        let segments = [segment] + additional
        let correction: TranscriptCorrectionEvent? = correctedText.map { text in
            TranscriptCorrectionEvent(
                id: UUID(uuidString: "A1000000-0000-4000-8000-000000000099")!,
                meetingID: meeting.id,
                baseTranscriptRevision: meeting.transcriptRevision,
                targetSegmentIDs: [segment.id],
                kind: .replaceText(text: text, language: "en"),
                sourceDeviceID: UUID(
                    uuidString: "A1000000-0000-4000-9000-000000000001")!,
                createdAt: Date(timeIntervalSince1970: 10))
        }
        let corrections = correction.map { [$0] } ?? []
        let revision = try TranscriptCorrectionRevision.current(
            meetingID: meeting.id,
            baseTranscriptRevision: meeting.transcriptRevision,
            history: corrections)
        let source: TranscriptCorrectionArtifactSource = summaryMatchesCorrection
            ? .revision(revision)
            : .legacyAccepted
        let evidence = includeEvidence ? [SummaryActionItemEvidence(
            actionItemID: actionItem.id,
            sourceTranscriptRevision: meeting.transcriptRevision,
            evidenceSegmentIDs: segments.map(\.id))] : []
        let detail = MeetingLibraryDetail(
            meeting: meeting,
            speakers: [speaker],
            segments: segments,
            corrections: corrections,
            correctionRevision: revision,
            summary: SummaryDraft(
                meetingID: meeting.id,
                recipeID: "general",
                language: summaryLanguage,
                markdown: "## Action items",
                actionItems: [actionItem],
                actionItemEvidence: evidence),
            summaryVersion: 1,
            summaryCorrectionSource: source)
        self.meeting = meeting
        self.speaker = speaker
        self.segment = segment
        self.actionItem = actionItem
        self.detail = detail
    }

    func prepare() -> PrepareGitHubIssueDraft {
        PrepareGitHubIssueDraft(
            library: QueryMeetingLibrary(reader: GitHubIssueReader(detail: detail)))
    }
}

private actor GitHubIssueReader: MeetingLibraryQueryReading {
    let detail: MeetingLibraryDetail?
    private(set) var detailReadCount = 0

    init(detail: MeetingLibraryDetail?) {
        self.detail = detail
    }

    func meetingLibraryMeetings(limit: Int?) -> [Meeting] {
        _ = limit
        return []
    }

    func meetingLibraryDetail(_ id: MeetingID) -> MeetingLibraryDetail? {
        _ = id
        detailReadCount += 1
        return detail
    }

    func meetingLibrarySearch(_ query: String, limit: Int) -> [LibrarySearchHit] {
        _ = query
        _ = limit
        return []
    }

    func meetingLibraryOpenItems(limit: Int) -> [LibraryOpenItem] {
        _ = limit
        return []
    }
}

private actor GitHubIssuePublisherSpy: GitHubIssuePublishing {
    private(set) var drafts: [GitHubIssueDraft] = []

    func publish(_ draft: GitHubIssueDraft) -> URL {
        drafts.append(draft)
        return URL(string: "https://github.com/portavoz/demo/issues/42")!
    }
}

private func XCTAssertThrowsErrorAsync<T: Equatable>(
    _ expression: @autoclosure () async throws -> some Any,
    equals expected: T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error \(expected)", file: file, line: line)
    } catch let error as T {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
