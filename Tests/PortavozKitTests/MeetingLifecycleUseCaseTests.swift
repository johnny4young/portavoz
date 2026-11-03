import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

final class MeetingLifecycleUseCaseTests: XCTestCase {
    func testDeleteAndRestoreDelegateTheRequestedMutation() async throws {
        let store = MeetingLifecycleStoreSpy()
        let deletedID = MeetingID()
        let restoredID = MeetingID()

        try await DeleteMeeting(store: store)(deletedID)
        try await RestoreMeeting(store: store)(restoredID)

        let operations = await store.recordedOperations()
        XCTAssertEqual(operations, [.delete(deletedID), .restore(restoredID)])
    }

    func testLifecycleUseCasesPropagatePersistenceFailures() async {
        let store = FailingMeetingLifecycleStore()

        do {
            try await DeleteMeeting(store: store)(MeetingID())
            XCTFail("DeleteMeeting must not swallow persistence failures")
        } catch is FailingMeetingLifecycleStore.Failure {
            // Expected: presentation decides how to surface or tolerate it.
        } catch {
            XCTFail("unexpected delete error: \(error)")
        }

        do {
            try await RestoreMeeting(store: store)(MeetingID())
            XCTFail("RestoreMeeting must not swallow persistence failures")
        } catch is FailingMeetingLifecycleStore.Failure {
            // Expected: presentation decides how to surface or tolerate it.
        } catch {
            XCTFail("unexpected restore error: \(error)")
        }
    }

    func testDeleteRestoreConserveTheRealMeetingAggregate() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Arquitectura local",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_030),
            language: "es")
        let speaker = Speaker(
            meetingID: meeting.id, label: "S1", displayName: "Ana")
        let segment = TranscriptSegment(
            meetingID: meeting.id, speakerID: speaker.id, channel: .system,
            text: "conservar el agregado", language: "es",
            startTime: 2, endTime: 12, isFinal: true)
        try await store.save(meeting)
        try await store.save([speaker])
        try await store.save([segment])

        let beforeDetailValue = try await store.detail(meeting.id)
        let beforeDetail = try XCTUnwrap(beforeDetailValue)
        let beforeMix = try await store.voiceMixes(for: [meeting.id])

        try await DeleteMeeting(store: store)(meeting.id)

        let liveAfterDelete = try await store.meetings()
        let detailAfterDelete = try await store.detail(meeting.id)
        let trashAfterDelete = try await store.deletedMeetings()
        let mixAfterDelete = try await store.voiceMixes(for: [meeting.id])
        XCTAssertTrue(liveAfterDelete.isEmpty)
        XCTAssertNil(detailAfterDelete)
        XCTAssertEqual(trashAfterDelete.map(\.meeting.id), [meeting.id])
        XCTAssertTrue(mixAfterDelete.isEmpty)

        try await RestoreMeeting(store: store)(meeting.id)

        let restoredDetailValue = try await store.detail(meeting.id)
        let restoredDetail = try XCTUnwrap(restoredDetailValue)
        let restoredMix = try await store.voiceMixes(for: [meeting.id])
        let trashAfterRestore = try await store.deletedMeetings()
        XCTAssertEqual(restoredDetail.meeting.id, beforeDetail.meeting.id)
        XCTAssertEqual(restoredDetail.meeting.title, beforeDetail.meeting.title)
        XCTAssertEqual(restoredDetail.speakers.map(\.id), beforeDetail.speakers.map(\.id))
        XCTAssertEqual(restoredDetail.segments.map(\.id), beforeDetail.segments.map(\.id))
        XCTAssertEqual(restoredDetail.segments.map(\.text), ["conservar el agregado"])
        XCTAssertEqual(restoredMix, beforeMix)
        XCTAssertTrue(trashAfterRestore.isEmpty)
    }
}

private actor MeetingLifecycleStoreSpy: MeetingLifecycleStore {
    enum Operation: Equatable, Sendable {
        case delete(MeetingID)
        case restore(MeetingID)
    }

    private var operations: [Operation] = []

    func delete(_ id: MeetingID) {
        operations.append(.delete(id))
    }

    func restore(_ id: MeetingID) {
        operations.append(.restore(id))
    }

    func recordedOperations() -> [Operation] {
        operations
    }
}

private struct FailingMeetingLifecycleStore: MeetingLifecycleStore {
    struct Failure: Error {}

    func delete(_ id: MeetingID) throws {
        throw Failure()
    }

    func restore(_ id: MeetingID) throws {
        throw Failure()
    }
}
