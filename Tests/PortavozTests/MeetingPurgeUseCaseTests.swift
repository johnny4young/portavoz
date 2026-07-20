import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

final class MeetingPurgeUseCaseTests: XCTestCase {
    func testPurgeDelegatesAudioAndStorageRemoval() async throws {
        let meetingID = MeetingID()
        let trace = PurgeOperationTrace()
        let store = MeetingPurgeStoreSpy(trace: trace)
        let files = MeetingAudioFilesSpy(trace: trace)

        let result = try await PurgeMeeting(store: store, audioFiles: files)(
            PurgeMeetingRequest(
                meetingID: meetingID,
                audioDirectory: "Audio/meeting"))

        let recordedPaths = await files.recordedPaths()
        let recordedPurges = await store.recordedPurges()
        let operations = await trace.recordedOperations()
        XCTAssertTrue(result.audioRemovalSucceeded)
        XCTAssertEqual(recordedPaths, ["Audio/meeting"])
        XCTAssertEqual(recordedPurges, [meetingID])
        XCTAssertEqual(operations, [.audio, .storage])
    }

    func testPurgeContinuesPastAudioFailureAndPropagatesStorageFailure() async throws {
        let audioFailureID = MeetingID()
        let audioFailureStore = MeetingPurgeStoreSpy()
        let failingFiles = MeetingAudioFilesSpy(failingPaths: ["Audio/unreadable"])

        let result = try await PurgeMeeting(
            store: audioFailureStore, audioFiles: failingFiles)(
                PurgeMeetingRequest(
                    meetingID: audioFailureID,
                    audioDirectory: "Audio/unreadable"))

        let audioFailurePurges = await audioFailureStore.recordedPurges()
        XCTAssertFalse(result.audioRemovalSucceeded)
        XCTAssertEqual(audioFailurePurges, [audioFailureID])

        let storageFailureID = MeetingID()
        let failingStore = MeetingPurgeStoreSpy(failingIDs: [storageFailureID])
        let successfulFiles = MeetingAudioFilesSpy()
        do {
            _ = try await PurgeMeeting(store: failingStore, audioFiles: successfulFiles)(
                PurgeMeetingRequest(
                    meetingID: storageFailureID,
                    audioDirectory: "Audio/removed-first"))
            XCTFail("storage purge failures must propagate")
        } catch is MeetingPurgeStoreSpy.Failure {
            // Expected: the presentation layer retains its best-effort policy.
        }
        let storageFailurePaths = await successfulFiles.recordedPaths()
        XCTAssertEqual(storageFailurePaths, ["Audio/removed-first"])
    }

    func testExpiredPurgeUsesStrictCutoffAndContinuesAfterOneFailure() async throws {
        let cutoff = Date(timeIntervalSince1970: 10_000)
        let first = MeetingPurgeCandidate(
            meetingID: MeetingID(), audioDirectory: "Audio/first",
            deletedAt: cutoff.addingTimeInterval(-2))
        let boundary = MeetingPurgeCandidate(
            meetingID: MeetingID(), audioDirectory: "Audio/boundary",
            deletedAt: cutoff)
        let second = MeetingPurgeCandidate(
            meetingID: MeetingID(), audioDirectory: nil,
            deletedAt: cutoff.addingTimeInterval(-1))
        let store = MeetingPurgeStoreSpy(
            candidates: [boundary, first, second], failingIDs: [first.meetingID])
        let files = MeetingAudioFilesSpy()

        let attempted = try await PurgeExpiredTrash(store: store, audioFiles: files)(cutoff)

        let recordedPurges = await store.recordedPurges()
        let recordedPaths = await files.recordedPaths()
        XCTAssertEqual(attempted, 2)
        XCTAssertEqual(recordedPurges, [first.meetingID, second.meetingID])
        XCTAssertEqual(recordedPaths, ["Audio/first"])
    }

    func testPurgeRemovesRealAggregateAndScratchAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-purge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let relativePath = "Audio/meeting"
        let audioDirectory = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: audioDirectory, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: audioDirectory.appendingPathComponent("system.caf"))

        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Expired", startedAt: Date(), audioDirectory: relativePath)
        try await store.save(meeting)
        try await store.delete(meeting.id)

        let result = try await PurgeMeeting(
            store: store, audioFiles: RootedMeetingAudioFiles(root: root))(
                PurgeMeetingRequest(
                    meetingID: meeting.id,
                    audioDirectory: relativePath))

        let allMeetings = try await store.meetings(includeDeleted: true)
        XCTAssertTrue(result.audioRemovalSucceeded)
        XCTAssertTrue(allMeetings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioDirectory.path))
    }
}

private actor MeetingPurgeStoreSpy: MeetingPurgeStore {
    struct Failure: Error {}

    private let candidates: [MeetingPurgeCandidate]
    private let failingIDs: Set<MeetingID>
    private let trace: PurgeOperationTrace?
    private var purgedIDs: [MeetingID] = []

    init(
        candidates: [MeetingPurgeCandidate] = [],
        failingIDs: Set<MeetingID> = [],
        trace: PurgeOperationTrace? = nil
    ) {
        self.candidates = candidates
        self.failingIDs = failingIDs
        self.trace = trace
    }

    func purge(_ id: MeetingID) async throws {
        await trace?.record(.storage)
        purgedIDs.append(id)
        if failingIDs.contains(id) { throw Failure() }
    }

    func meetingPurgeCandidates() -> [MeetingPurgeCandidate] {
        candidates
    }

    func recordedPurges() -> [MeetingID] {
        purgedIDs
    }
}

private actor MeetingAudioFilesSpy: MeetingAudioFiles {
    struct Failure: Error {}

    private let failingPaths: Set<String>
    private let trace: PurgeOperationTrace?
    private var paths: [String] = []

    init(
        failingPaths: Set<String> = [],
        trace: PurgeOperationTrace? = nil
    ) {
        self.failingPaths = failingPaths
        self.trace = trace
    }

    func removeAudioDirectory(_ relativePath: String) async throws {
        await trace?.record(.audio)
        paths.append(relativePath)
        if failingPaths.contains(relativePath) { throw Failure() }
    }

    func recordedPaths() -> [String] {
        paths
    }
}

private actor PurgeOperationTrace {
    enum Operation: Equatable, Sendable {
        case audio
        case storage
    }

    private var operations: [Operation] = []

    func record(_ operation: Operation) {
        operations.append(operation)
    }

    func recordedOperations() -> [Operation] {
        operations
    }
}

private struct RootedMeetingAudioFiles: MeetingAudioFiles {
    let root: URL

    func removeAudioDirectory(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(relativePath))
    }
}
