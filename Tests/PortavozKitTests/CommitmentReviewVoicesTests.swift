import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

final class CommitmentReviewVoicesTests: XCTestCase {
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
    private func seed(title: String = "Planning") async throws -> Fixture {
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
                text: "test both PRs together", startTime: 0, endTime: 40, isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id, speakerID: me.id, channel: .microphone,
                text: "I can take it", startTime: 40, endTime: 100, isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id, speakerID: unnamed.id, channel: .system,
                text: "before Thursday", startTime: 100, endTime: 200, isFinal: true)
        ]
        try await store.save(segments)
        return Fixture(meeting: meeting, me: me, marta: marta, unnamed: unnamed, segments: segments)
    }

    private func item(
        _ fixture: Fixture,
        evidence: [TranscriptSegment],
        status: TranscriptEvidenceStatus = .current,
        owner: CommitmentReviewQueueOwner? = nil
    ) -> CommitmentReviewQueueItem {
        CommitmentReviewQueueItem(
            meetingID: fixture.meeting.id,
            meetingTitle: fixture.meeting.title,
            meetingStartedAt: fixture.meeting.startedAt,
            meetingEndedAt: fixture.meeting.startedAt.addingTimeInterval(200),
            actionItem: ActionItem(text: "Test both PRs"),
            evidence: TranscriptEvidenceResolution(status: status, segments: evidence),
            evidenceCount: evidence.count,
            suggestedOwner: owner,
            reason: .newAfterMeeting)
    }

    func testFirstAttributedLineSaysWhoAndEveryLineMarksItsMoment() async throws {
        let planning = try await seed()
        let retro = try await seed(title: "Retro")
        let first = item(planning, evidence: [planning.segments[0], planning.segments[2]])
        let second = item(retro, evidence: [retro.segments[1]])

        let voices = try await LoadCommitmentReviewVoices(reader: store)([first, second])

        XCTAssertEqual(voices.items[first.id]?.voice?.speakerID, planning.marta.id)
        XCTAssertEqual(voices.items[first.id]?.voice?.name, "Marta")
        XCTAssertEqual(voices.items[first.id]?.moments, [0, 0.5])
        XCTAssertEqual(voices.items[second.id]?.voice?.identity, .me)
        XCTAssertEqual(voices.items[second.id]?.moments, [0.2])
        XCTAssertEqual(voices.strips.map(\.meetingID), [planning.meeting.id, retro.meeting.id])
        XCTAssertEqual(voices.strips.first?.source.duration, 200)
    }

    func testStaleEvidenceKeepsTheStripButClaimsNoVoiceOrMoment() async throws {
        let planning = try await seed()
        let stale = item(planning, evidence: [planning.segments[0]], status: .stale)

        let voices = try await LoadCommitmentReviewVoices(reader: store)([stale])

        XCTAssertNil(voices.items[stale.id]?.voice)
        XCTAssertEqual(voices.items[stale.id]?.moments, [])
        XCTAssertEqual(voices.strips.map(\.meetingID), [planning.meeting.id])
    }

    func testEmptyPageReadsNothing() async throws {
        let voices = try await LoadCommitmentReviewVoices(reader: FailingReader())([])
        XCTAssertEqual(voices, .empty)
    }

    func testMergingTakesTheNewerStripForAMeetingAlreadyRead() async throws {
        let planning = try await seed()
        let first = item(planning, evidence: [planning.segments[0]])
        let second = item(planning, evidence: [planning.segments[1]])
        func strip(named name: String?) -> CommitmentReviewVoices.Strip {
            .init(meetingID: planning.meeting.id, source: VoiceStripSource(columns: MeetingVoiceColumns(
                duration: 200,
                columns: [0],
                voices: [.init(speakerID: planning.marta.id, isMe: false, label: "S1", displayName: name,
                               talkSeconds: 40, firstHeard: 0)])))
        }
        let older = CommitmentReviewVoices(
            items: [first.id: .init(voice: nil, moments: [0])], strips: [strip(named: nil)])
        let newer = CommitmentReviewVoices(
            items: [second.id: .init(voice: nil, moments: [0.2])], strips: [strip(named: "Marta")])

        let merged = older.merging(newer, keeping: [first, second])

        XCTAssertEqual(merged.strips, newer.strips, "a rename read later replaces the strip")
        XCTAssertEqual(merged.items.keys.sorted(), [first.id, second.id].sorted())
    }

    func testOwnerChoicesPutTheSuggestionFirstThenTheMeetingsPeopleOnce() async throws {
        let planning = try await seed()
        let marta = try await store.createPersonAndLink(
            speakerID: planning.marta.id, preferredName: "Marta", source: .manualName)
        let ilarion = try await store.createPersonAndLink(
            speakerID: planning.unnamed.id, preferredName: "Ilarion", source: .manualName)
        let suggested = CommitmentReviewQueueOwner(personID: ilarion.person.id, displayName: "Ilarion")
        let candidate = item(planning, evidence: [planning.segments[0]], owner: suggested)

        let voices = try await LoadCommitmentReviewVoices(reader: store)([candidate])
        let choices = voices.ownerChoices(for: planning.meeting.id, suggested: suggested)

        XCTAssertEqual(choices.map(\.personID), [ilarion.person.id, marta.person.id])
        XCTAssertEqual(choices.map(\.displayName), ["Ilarion", "Marta"])
        XCTAssertEqual(
            CommitmentReviewVoices.empty.ownerChoices(for: planning.meeting.id, suggested: suggested)
                .map(\.personID),
            [ilarion.person.id],
            "without the strip, the suggested owner is still offered")
    }
}

private struct FailingReader: MeetingVoiceAttributionReading {
    struct Refused: Error {}

    func askCitedLines(_: [MeetingID: [UUID]]) async throws -> [MeetingID: AskCitedLines] {
        throw Refused()
    }

    func voiceColumns(for _: [MeetingID]) async throws -> [MeetingID: MeetingVoiceColumns] {
        throw Refused()
    }
}
