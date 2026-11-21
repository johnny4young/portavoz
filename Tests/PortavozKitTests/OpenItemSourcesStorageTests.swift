import PortavozCore
@testable import StorageKit
import XCTest

final class OpenItemSourcesStorageTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    func testSourcesNameWhoSaidEachItemWhenAndWhoOwnsIt() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Weekly sync", startedAt: base, endedAt: base.addingTimeInterval(600))
        try await store.save(meeting)
        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        let marta = Speaker(meetingID: meeting.id, label: "S1", displayName: "Marta")
        try await store.save([me, marta])
        let segments = [(marta, 10.0), (me, 40.0), (marta, 90.0)].map { speaker, start in
            TranscriptSegment(
                meetingID: meeting.id, speakerID: speaker.id, channel: speaker.isMe ? .microphone : .system,
                text: "Line at \(start)", startTime: start, endTime: start + 20, isFinal: true)
        }
        try await store.save(segments)
        let asked = ActionItem(text: "Send the plan", ownerSpeakerID: me.id)
        let said = ActionItem(text: "Review the docs", ownerSpeakerID: me.id)
        let corrected = ActionItem(text: "Book the room", ownerSpeakerID: marta.id)
        let bare = ActionItem(text: "Somebody books lunch")
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id, recipeID: Recipe.general.id, language: "en", markdown: "Summary.",
            actionItems: [asked, said, corrected, bare],
            actionItemEvidence: [
                SummaryActionItemEvidence(actionItemID: asked.id, evidenceSegmentIDs: [segments[0].id]),
                SummaryActionItemEvidence(actionItemID: said.id, evidenceSegmentIDs: [segments[1].id]),
                SummaryActionItemEvidence(actionItemID: corrected.id, evidenceSegmentIDs: [segments[2].id]),
            ]))
        let due = base.addingTimeInterval(86_400)
        _ = try await store.confirmCommitment(
            CommitmentConfirmation(title: said.text, dueAt: due, origin: .generatedActionItem(said.id)), at: base)
        // Attribution follows the corrected transcript, like the voice strip.
        _ = try await store.appendTranscriptCorrections([
            TranscriptCorrectionEvent(
                meetingID: meeting.id, baseTranscriptRevision: meeting.transcriptRevision,
                targetSegmentIDs: [segments[2].id], kind: .changeSpeaker(me.id),
                sourceDeviceID: UUID(), createdAt: base),
        ])

        let sources = try await store.openItemSources(for: [asked.id, said.id, corrected.id, bare.id, UUID()])

        XCTAssertEqual(sources.count, 4, "an unknown item has no source")
        let askedSource = try XCTUnwrap(sources[asked.id])
        XCTAssertEqual(askedSource.saidBy?.displayName, "Marta")
        XCTAssertEqual(askedSource.owner?.isMe, true)
        XCTAssertEqual(askedSource.time, 10)
        XCTAssertFalse(askedSource.ownerSaidIt)
        XCTAssertNil(askedSource.dueAt, "only a confirmed commitment carries a due date")

        let saidSource = try XCTUnwrap(sources[said.id])
        XCTAssertTrue(saidSource.ownerSaidIt)
        XCTAssertEqual(saidSource.time, 40)
        XCTAssertEqual(saidSource.dueAt, due)

        XCTAssertEqual(sources[corrected.id]?.saidBy?.isMe, true)
        XCTAssertEqual(sources[corrected.id]?.owner?.displayName, "Marta")

        let bareSource = try XCTUnwrap(sources[bare.id])
        XCTAssertNil(bareSource.saidBy)
        XCTAssertNil(bareSource.time)
        XCTAssertNil(bareSource.owner)
        let none = try await store.openItemSources(for: [])
        XCTAssertTrue(none.isEmpty)
    }
}
