import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

final class AskEvidenceTests: XCTestCase {
    private var store: MeetingStore!

    override func setUpWithError() throws {
        store = try MeetingStore.inMemory()
    }

    private struct Fixture {
        let meeting: Meeting
        let me: Speaker
        let marta: Speaker
        let unnamed: Speaker
        let segments: [TranscriptSegment]
    }

    /// Marta 0–40 s, you 40–100 s, an unnamed voice 100–200 s.
    private func seed(title: String = "Sprint demo") async throws -> Fixture {
        let meeting = Meeting(title: title, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try await store.save(meeting)
        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        var marta = Speaker(meetingID: meeting.id, label: "S1")
        marta.displayName = "Marta"
        let unnamed = Speaker(meetingID: meeting.id, label: "S2")
        try await store.save([me, marta, unnamed])
        let segments = [
            TranscriptSegment(
                meetingID: meeting.id, speakerID: marta.id, channel: .system,
                text: "the dashboards move before Friday", startTime: 0, endTime: 40, isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id, speakerID: me.id, channel: .microphone,
                text: "I will migrate them", startTime: 40, endTime: 100, isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id, speakerID: unnamed.id, channel: .system,
                text: "still no access", startTime: 100, endTime: 200, isFinal: true)
        ]
        try await store.save(segments)
        return Fixture(meeting: meeting, me: me, marta: marta, unnamed: unnamed, segments: segments)
    }

    private func citation(_ segment: TranscriptSegment, in meeting: Meeting) -> AskCitation {
        AskCitation(
            segmentID: segment.id, meetingID: meeting.id, meetingTitle: meeting.title,
            timestamp: segment.startTime, text: segment.text)
    }

    func testRowsFollowCitationOrderWithVoiceMeetingAndMoment() async throws {
        let fixture = try await seed()
        let other = try await seed(title: "Retro")
        let citations = [
            citation(fixture.segments[1], in: fixture.meeting),
            citation(other.segments[0], in: other.meeting),
            citation(fixture.segments[2], in: fixture.meeting)
        ]

        let evidence = try await LoadAskEvidence(reader: store)(
            citations: citations, answer: "You own it [1]. Nobody took access [3][3] [9].")

        XCTAssertEqual(evidence.rows.map(\.number), [1, 2, 3])
        XCTAssertEqual(evidence.rows.map(\.citation), citations)
        XCTAssertEqual(evidence.rows.map(\.isCitedByAnswer), [true, false, true])
        XCTAssertEqual(evidence.rows.map(\.voice?.speakerID), [fixture.me.id, other.marta.id, fixture.unnamed.id])
        XCTAssertEqual(evidence.rows.map { $0.voice?.identity == .me }, [true, false, false])
        XCTAssertEqual(evidence.rows.map(\.voice?.name), [nil, "Marta", nil])
        XCTAssertEqual(evidence.rows[2].voice?.label, "S2")
        XCTAssertEqual(evidence.rows[0].voice?.key, "me")
        XCTAssertEqual(evidence.rows.map(\.meetingStartedAt), Array(repeating: fixture.meeting.startedAt, count: 3))
        XCTAssertEqual(evidence.rows.map(\.position), [0.2, 0, 0.5])
        XCTAssertEqual(evidence.strips.map(\.meetingID), [fixture.meeting.id, other.meeting.id])
        XCTAssertEqual(evidence.strips.first?.source.duration, 200)
        XCTAssertEqual(evidence.meetingCount, 2)
        XCTAssertEqual(evidence.voiceCount, 3)
    }

    func testNoAnswerCitesNothingAndNoCitationsReadNothing() async throws {
        let fixture = try await seed()
        let evidence = try await LoadAskEvidence(reader: store)(
            citations: [citation(fixture.segments[0], in: fixture.meeting)], answer: nil)
        XCTAssertEqual(evidence.rows.map(\.isCitedByAnswer), [false])
        XCTAssertEqual(evidence.rows.first?.voice?.name, "Marta")

        let empty = try await LoadAskEvidence(reader: store)(citations: [], answer: "Nothing [1].")
        XCTAssertEqual(empty, .empty)
    }

    func testAttributionFollowsSpeakerFixesAndSplitParts() async throws {
        let fixture = try await seed()
        let revision = fixture.meeting.transcriptRevision
        _ = try await store.appendTranscriptCorrections([
            TranscriptCorrectionEvent(
                meetingID: fixture.meeting.id, baseTranscriptRevision: revision,
                targetSegmentIDs: [fixture.segments[0].id], kind: .changeSpeaker(fixture.unnamed.id),
                sourceDeviceID: UUID(), createdAt: Date(timeIntervalSince1970: 10))
        ])
        let part = TranscriptCorrectionPart(
            text: "them", speakerID: fixture.marta.id, language: nil, startTime: 70, endTime: 100)
        _ = try await store.appendTranscriptCorrection(TranscriptCorrectionEvent(
            meetingID: fixture.meeting.id, baseTranscriptRevision: revision,
            targetSegmentIDs: [fixture.segments[1].id],
            kind: .split([
                TranscriptCorrectionPart(
                    text: "I will migrate", speakerID: fixture.me.id, language: nil, startTime: 40, endTime: 70),
                part
            ]),
            sourceDeviceID: UUID(), createdAt: Date(timeIntervalSince1970: 11)))
        let splitPart = AskCitation(
            segmentID: part.id, sourceSegmentIDs: [fixture.segments[1].id], meetingID: fixture.meeting.id,
            meetingTitle: fixture.meeting.title, timestamp: 70, text: "them")

        let evidence = try await LoadAskEvidence(reader: store)(
            citations: [
                citation(fixture.segments[0], in: fixture.meeting),
                splitPart,
                citation(fixture.segments[1], in: fixture.meeting)
            ],
            answer: nil)

        XCTAssertEqual(
            evidence.rows.map(\.voice?.speakerID), [fixture.unnamed.id, fixture.marta.id, fixture.me.id],
            "a split part reads as its own speaker; its accepted segment as the first part's")
    }

    func testASplitPartNobodySaysNeverBorrowsItsSegmentsSpeaker() async throws {
        let fixture = try await seed()
        let silent = TranscriptCorrectionPart(
            text: "them", speakerID: nil, language: nil, startTime: 70, endTime: 100)
        _ = try await store.appendTranscriptCorrection(TranscriptCorrectionEvent(
            meetingID: fixture.meeting.id, baseTranscriptRevision: fixture.meeting.transcriptRevision,
            targetSegmentIDs: [fixture.segments[1].id],
            kind: .split([
                TranscriptCorrectionPart(
                    text: "I will migrate", speakerID: fixture.me.id, language: nil, startTime: 40, endTime: 70),
                silent
            ]),
            sourceDeviceID: UUID(), createdAt: Date(timeIntervalSince1970: 10)))
        let cited = AskCitation(
            segmentID: silent.id, sourceSegmentIDs: [fixture.segments[1].id], meetingID: fixture.meeting.id,
            meetingTitle: fixture.meeting.title, timestamp: 70, text: "them")

        let evidence = try await LoadAskEvidence(reader: store)(citations: [cited], answer: nil)

        XCTAssertNil(evidence.rows.first?.voice)
        XCTAssertEqual(evidence.rows.first?.position, 0.35)
    }

    func testSuppressedLinesAndDeletedMeetingsKeepTheirRowWithoutAVoice() async throws {
        let fixture = try await seed()
        let deleted = try await seed(title: "Gone")
        _ = try await store.appendTranscriptCorrection(TranscriptCorrectionEvent(
            meetingID: fixture.meeting.id, baseTranscriptRevision: fixture.meeting.transcriptRevision,
            targetSegmentIDs: [fixture.segments[2].id], kind: .suppress,
            sourceDeviceID: UUID(), createdAt: Date(timeIntervalSince1970: 10)))
        try await store.delete(deleted.meeting.id)

        let evidence = try await LoadAskEvidence(reader: store)(
            citations: [
                citation(fixture.segments[2], in: fixture.meeting),
                citation(deleted.segments[0], in: deleted.meeting)
            ],
            answer: "[1] [2]")

        XCTAssertEqual(evidence.rows.map(\.number), [1, 2])
        XCTAssertEqual(evidence.rows.map(\.voice), [nil, nil])
        XCTAssertNotNil(evidence.rows[0].meetingStartedAt)
        XCTAssertNotNil(evidence.rows[0].position)
        XCTAssertNil(evidence.rows[1].meetingStartedAt)
        XCTAssertNil(evidence.rows[1].position)
        XCTAssertEqual(evidence.strips.map(\.meetingID), [fixture.meeting.id])
    }

    func testAMomentPastTheStripClampsToItsEnd() async throws {
        let fixture = try await seed()
        let late = AskCitation(
            segmentID: fixture.segments[2].id, meetingID: fixture.meeting.id,
            meetingTitle: fixture.meeting.title, timestamp: 900, text: "late")
        let evidence = try await LoadAskEvidence(reader: store)(citations: [late], answer: nil)
        XCTAssertEqual(evidence.rows.first?.position, 1)
    }
    func testOpenCommitmentsAreTheConfirmedOnesBehindACitedLine() async throws {
        let fixture = try await seed()
        func confirm(_ text: String, segment: TranscriptSegment) async throws -> CommitmentID {
            let item = ActionItem(text: text, ownerSpeakerID: fixture.me.id)
            _ = try await store.saveSummary(SummaryDraft(
                meetingID: fixture.meeting.id, recipeID: Recipe.general.id, language: "en",
                markdown: text, actionItems: [item],
                actionItemEvidence: [SummaryActionItemEvidence(actionItemID: item.id, evidenceSegmentIDs: [segment.id])]))
            return try await store.confirmCommitment(CommitmentConfirmation(
                title: text, assignee: .me, origin: .generatedActionItem(item.id))).commitment.id
        }
        let open = try await confirm("Migrate the dashboards", segment: fixture.segments[1])
        let done = try await confirm("Ship the access fix", segment: fixture.segments[1])
        _ = try await confirm("Unrelated", segment: fixture.segments[0])
        _ = try await store.applyCommitmentTransition(.complete, to: done)

        let evidence = try await LoadAskEvidence(reader: store)(
            citations: [citation(fixture.segments[1], in: fixture.meeting)], answer: "[1]")

        XCTAssertEqual(evidence.openCommitments, [open])
    }
}
