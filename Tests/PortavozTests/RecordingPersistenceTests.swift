import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class RecordingPersistenceTests: XCTestCase {
    private func shell(
        id: MeetingID = MeetingID(),
        directory: String? = nil
    ) -> Meeting {
        Meeting(
            id: id,
            title: "Durable recording",
            startedAt: Date(timeIntervalSince1970: 1_783_695_600),
            audioDirectory: directory ?? "Audio/\(id.rawValue.uuidString)",
            lifecycleState: .recording)
    }

    private func assets(for meeting: Meeting, channels: [AudioChannel]) -> [AudioAsset] {
        channels.map { channel in
            AudioAsset.pendingCapture(
                meetingID: meeting.id,
                channel: channel,
                relativePath: "\(meeting.audioDirectory!)/\(channel.rawValue).caf",
                at: meeting.startedAt)
        }
    }

    private func assertReservationRejected(
        by store: MeetingStore,
        meeting: Meeting,
        assets: [AudioAsset],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            try await store.beginRecording(meeting, assets: assets)
            XCTFail("invalid reservation was persisted", file: file, line: line)
        } catch {
            XCTAssertTrue(error is StorageError, file: file, line: line)
        }
        let detail = try await store.detail(meeting.id)
        XCTAssertNil(detail, file: file, line: line)
    }

    func testBeginRecordingAtomicallyPersistsShellAndPendingAssets() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = shell()
        let reserved = assets(for: meeting, channels: [.microphone, .system])

        try await store.beginRecording(meeting, assets: reserved)

        let storedDetail = try await store.detail(meeting.id)
        let detail = try XCTUnwrap(storedDetail)
        XCTAssertEqual(detail.meeting.lifecycleState, .recording)
        XCTAssertNil(detail.meeting.endedAt)
        XCTAssertEqual(detail.meeting.audioDirectory, meeting.audioDirectory)
        let persisted = try await store.audioAssets(for: meeting.id)
        XCTAssertEqual(persisted.map(\.channel), [.microphone, .system])
        XCTAssertTrue(persisted.allSatisfy { $0.role == .capture })
        XCTAssertTrue(persisted.allSatisfy { $0.healthStatus == .pending })
        XCTAssertTrue(persisted.allSatisfy { $0.container == nil && $0.sha256 == nil })

        var corrupt = AudioAssetRecord(reserved[0])
        corrupt.channel = "corrupt-channel"
        XCTAssertThrowsError(try corrupt.asset) { error in
            guard case StorageError.invalidPersistedValue(
                table: "audioAsset", column: "channel", value: "corrupt-channel") = error
            else { return XCTFail("wrong error: \(error)") }
        }
        corrupt.channel = AudioChannel.microphone.rawValue
        corrupt.healthStatus = "corrupt-health"
        XCTAssertThrowsError(try corrupt.asset) { error in
            guard case StorageError.invalidPersistedValue(
                table: "audioAsset", column: "healthStatus", value: "corrupt-health") = error
            else { return XCTFail("wrong error: \(error)") }
        }
        corrupt.healthStatus = AudioAssetHealthStatus.pending.rawValue
        corrupt.relativePath = "/tmp/microphone.caf"
        XCTAssertThrowsError(try corrupt.asset) { error in
            guard case StorageError.absolutePathRejected = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testBeginRecordingRollsBackShellWhenAnAssetConflicts() async throws {
        let store = try MeetingStore.inMemory()
        let first = shell(directory: "Audio/shared-reservation")
        try await store.beginRecording(
            first, assets: assets(for: first, channels: [.microphone]))

        let second = shell(directory: "Audio/shared-reservation")
        do {
            try await store.beginRecording(
                second, assets: self.assets(for: second, channels: [.microphone]))
            XCTFail("a reserved path cannot belong to two recordings")
        } catch {
            XCTAssertTrue(error is DatabaseError, "wrong error: \(error)")
        }

        let secondDetail = try await store.detail(second.id)
        let meetings = try await store.meetings()
        let firstAssets = try await store.audioAssets(for: first.id)
        XCTAssertNil(secondDetail)
        XCTAssertEqual(meetings.map(\.id), [first.id])
        XCTAssertEqual(firstAssets.count, 1)
        try await store.database.read { db in
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testDiscardUnstartedRecordingIsLimitedToEmptyRecordingShells() async throws {
        let store = try MeetingStore.inMemory()
        let disposable = shell()
        try await store.beginRecording(
            disposable, assets: assets(for: disposable, channels: [.microphone]))

        let discarded = try await store.discardUnstartedRecording(disposable.id)
        let discardedDetail = try await store.detail(disposable.id)
        let discardedAssets = try await store.audioAssets(for: disposable.id)
        let discardedAgain = try await store.discardUnstartedRecording(disposable.id)
        XCTAssertTrue(discarded)
        XCTAssertNil(discardedDetail)
        XCTAssertTrue(discardedAssets.isEmpty)
        XCTAssertFalse(discardedAgain)

        let protected = shell()
        try await store.beginRecording(
            protected, assets: assets(for: protected, channels: [.microphone]))
        try await store.save([
            TranscriptSegment(
                meetingID: protected.id,
                channel: .microphone,
                text: "This captured content makes the shell a user meeting.",
                startTime: 0,
                endTime: 1,
                isFinal: true)
        ])
        do {
            _ = try await store.discardUnstartedRecording(protected.id)
            XCTFail("a shell with transcript content must be preserved")
        } catch {
            guard case StorageError.invalidRecordingReservation = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        let protectedDetail = try await store.detail(protected.id)
        XCTAssertNotNil(protectedDetail)

        var invalid = shell()
        invalid.lifecycleState = .ready
        do {
            try await store.beginRecording(
                invalid, assets: self.assets(for: invalid, channels: [.microphone]))
            XCTFail("only recording lifecycle shells can be reserved")
        } catch {
            guard case StorageError.invalidRecordingReservation = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        let invalidDetail = try await store.detail(invalid.id)
        XCTAssertNil(invalidDetail)
    }

    func testBeginRecordingRejectsInvalidReservationShapesBeforeWriting() async throws {
        let store = try MeetingStore.inMemory()

        let missingAssets = shell()
        try await assertReservationRejected(
            by: store, meeting: missingAssets, assets: [])

        let traversal = shell(directory: "Audio/../escape")
        try await assertReservationRejected(
            by: store,
            meeting: traversal,
            assets: assets(for: traversal, channels: [.microphone]))

        let duplicateChannel = shell()
        let duplicateAssets = assets(
            for: duplicateChannel, channels: [.microphone, .microphone])
        try await assertReservationRejected(
            by: store, meeting: duplicateChannel, assets: duplicateAssets)

        let wrongOwner = shell()
        let anotherMeeting = shell()
        try await assertReservationRejected(
            by: store,
            meeting: wrongOwner,
            assets: assets(for: anotherMeeting, channels: [.microphone]))

        let wrongPath = shell()
        var mismatchedPath = assets(for: wrongPath, channels: [.microphone])
        mismatchedPath[0].relativePath = "Audio/somewhere-else/microphone.caf"
        try await assertReservationRejected(
            by: store, meeting: wrongPath, assets: mismatchedPath)

        let finalized = shell()
        var finalizedAssets = assets(for: finalized, channels: [.microphone])
        finalizedAssets[0].healthStatus = .healthy
        try await assertReservationRejected(
            by: store, meeting: finalized, assets: finalizedAssets)

        let prematureMetadata = shell()
        var metadataAssets = assets(for: prematureMetadata, channels: [.microphone])
        metadataAssets[0].container = "caf"
        try await assertReservationRejected(
            by: store, meeting: prematureMetadata, assets: metadataAssets)

        let derived = shell()
        var derivedAssets = assets(for: derived, channels: [.microphone])
        derivedAssets[0].role = AudioAssetRole(rawValue: "compressed")
        try await assertReservationRejected(
            by: store, meeting: derived, assets: derivedAssets)

        var preclassified = shell()
        preclassified.language = "en"
        try await assertReservationRejected(
            by: store,
            meeting: preclassified,
            assets: assets(for: preclassified, channels: [.microphone]))

        let persistedMeetings = try await store.meetings()
        XCTAssertTrue(persistedMeetings.isEmpty)
    }
}
