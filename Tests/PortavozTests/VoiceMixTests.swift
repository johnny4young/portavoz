import PortavozCore
import StorageKit
import XCTest

final class VoiceMixTests: XCTestCase {
    private var store: MeetingStore!

    override func setUpWithError() throws {
        store = try MeetingStore.inMemory()
    }

    /// Seeds one meeting: Me speaks 6 s, Marta 3 s, an unnamed S1 1 s.
    private func seed() async throws -> Meeting {
        let meeting = Meeting(title: "Sprint demo", startedAt: Date())
        try await store.save(meeting)
        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        var marta = Speaker(meetingID: meeting.id, label: "S2")
        marta.displayName = "Marta"
        let s1 = Speaker(meetingID: meeting.id, label: "S1")
        try await store.save([me, marta, s1])
        try await store.save([
            TranscriptSegment(
                meetingID: meeting.id, speakerID: me.id, channel: .microphone,
                text: "hi", startTime: 0, endTime: 6, isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id, speakerID: marta.id, channel: .system,
                text: "hola", startTime: 6, endTime: 9, isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id, speakerID: s1.id, channel: .system,
                text: "sí", startTime: 9, endTime: 10, isFinal: true),
        ])
        return meeting
    }

    func testMixFractionsSumToOneOrderedByTalkTime() async throws {
        let meeting = try await seed()
        let mixes = try await store.voiceMixes(for: [meeting.id])
        let slices = try XCTUnwrap(mixes[meeting.id])

        XCTAssertEqual(slices.count, 3)
        XCTAssertEqual(slices.map(\.order), [0, 1, 2])
        // Largest first: Me (6/10), Marta (3/10), S1 (1/10).
        XCTAssertTrue(slices[0].isMe)
        XCTAssertEqual(slices[0].fraction, 0.6, accuracy: 0.0001)
        XCTAssertEqual(slices[1].displayName, "Marta")
        XCTAssertEqual(slices[1].fraction, 0.3, accuracy: 0.0001)
        XCTAssertNil(slices[2].displayName)
        XCTAssertEqual(slices.reduce(0) { $0 + $1.fraction }, 1.0, accuracy: 0.0001)
    }

    func testEmptyInputReturnsEmpty() async throws {
        let mixes = try await store.voiceMixes(for: [])
        XCTAssertTrue(mixes.isEmpty)
    }

    func testMeetingWithNoAttributedSpeechIsAbsent() async throws {
        // A meeting whose only segment has no speaker contributes nothing.
        let meeting = Meeting(title: "Silent", startedAt: Date())
        try await store.save(meeting)
        try await store.save([
            TranscriptSegment(
                meetingID: meeting.id, speakerID: nil, channel: .system,
                text: "…", startTime: 0, endTime: 5, isFinal: true)
        ])
        let mixes = try await store.voiceMixes(for: [meeting.id])
        XCTAssertNil(mixes[meeting.id])
    }
}
