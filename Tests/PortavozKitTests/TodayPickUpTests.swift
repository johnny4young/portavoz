@testable import ApplicationKit
import PortavozCore
import StorageKit
import XCTest

final class TodayPickUpTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func meeting(_ title: String, hoursAgo: Double, minutes: Double = 60) -> Meeting {
        let start = base.addingTimeInterval(-hoursAgo * 3_600)
        return Meeting(title: title, startedAt: start, endedAt: start.addingTimeInterval(minutes * 60))
    }

    private func position(
        _ meeting: Meeting, _ seconds: TimeInterval, heard: Bool = false, listened: TimeInterval = 0
    ) -> (MeetingID, MeetingPlaybackPosition) {
        (meeting.id, MeetingPlaybackPosition(
            meetingID: meeting.id, seconds: seconds, isHeard: heard, updatedAt: base.addingTimeInterval(listened)))
    }

    func testStoppedMeetingsLeadByLastListenThenUnheardByRecency() {
        let newest = meeting("Newest", hoursAgo: 1)
        let heard = meeting("Heard", hoursAgo: 2)
        let older = meeting("Older stopped", hoursAgo: 3)
        let recent = meeting("Recent stopped", hoursAgo: 4)
        let barely = meeting("Barely played", hoursAgo: 5)
        var live = Meeting(title: "Live", startedAt: base)
        live.lifecycleState = .recording
        let positions = Dictionary(uniqueKeysWithValues: [
            position(heard, 600, heard: true),
            position(older, 1_200, listened: 10),
            position(recent, 1_880, listened: 20),
            position(barely, 0.5),
        ])

        let rows = TodayPickUp.rows(
            meetings: [live, newest, heard, older, recent, barely], positions: positions, limit: 10)

        XCTAssertEqual(rows.map(\.meeting.title), ["Recent stopped", "Older stopped", "Newest", "Barely played"])
        XCTAssertEqual(rows[0].progress, .stopped(at: 1_880))
        XCTAssertEqual(try XCTUnwrap(rows[0].playedFraction(of: 0)), 1_880 / 3_600, accuracy: 0.0001)
        XCTAssertEqual(rows[0].playedFraction(of: 1_880 * 2), 0.5, "the strip's own span wins")
        XCTAssertEqual(rows[2].progress, .unheard)
        XCTAssertEqual(rows[2].playedFraction(of: 0), 0)
        XCTAssertEqual(rows[3].progress, .unheard, "under a second in opens at the start")
        XCTAssertEqual(TodayPickUp.rows(meetings: [newest, older, recent, barely], positions: positions).count, 3)

        let unread = TodayPickUp.rows(meetings: [newest, heard, older], positions: nil)
        XCTAssertEqual(unread.map(\.meeting.title), ["Newest", "Heard", "Older stopped"])
        XCTAssertTrue(unread.allSatisfy { $0.progress == nil }, "nothing reads unheard before positions load")
        XCTAssertNil(unread[0].playedFraction(of: 100))
    }

    func testOnlyRecentFinishedMeetingsAreCandidates() {
        let meetings = (0..<30).map { meeting("M\($0)", hoursAgo: Double($0)) }
        XCTAssertEqual(TodayPickUp.candidates(meetings).count, TodayPickUp.candidateLimit)
        XCTAssertEqual(TodayPickUp.candidates([Meeting(title: "Open", startedAt: base)]).count, 0)
    }

    func testAFailedPartIsNilAndTheOtherStillLoads() async throws {
        let store = FakeTodayWorkStore()
        let id = MeetingID()
        store.positions = [id: MeetingPlaybackPosition(meetingID: id, seconds: 30, isHeard: false, updatedAt: base)]
        store.failsSources = true

        let work = try await LoadTodayWork(store: store).execute(.init(meetingIDs: [id], itemIDs: [UUID()]))

        XCTAssertEqual(work.positions?[id]?.seconds, 30)
        XCTAssertNil(work.sources, "a failed read must not read as empty")
    }
}

private final class FakeTodayWorkStore: TodayWorkReading, @unchecked Sendable {
    var positions: [MeetingID: MeetingPlaybackPosition] = [:]
    var failsSources = false

    func playbackPositions(for meetingIDs: [MeetingID]) async throws -> [MeetingID: MeetingPlaybackPosition] {
        positions
    }

    func openItemSources(for itemIDs: [UUID]) async throws -> [UUID: OpenItemSource] {
        if failsSources { throw CocoaError(.fileReadUnknown) }
        return [:]
    }
}
