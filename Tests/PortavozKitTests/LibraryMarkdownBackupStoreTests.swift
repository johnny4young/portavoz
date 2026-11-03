import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class LibraryMarkdownBackupStoreTests: XCTestCase {
    func testStageIsCoherentOrderedPrivateAndIsolatesCorruptAggregate() async throws {
        let stagingRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let store = try MeetingStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let older = Meeting(title: "Older", startedAt: base)
        let newer = Meeting(
            title: "Newer",
            startedAt: base.addingTimeInterval(60))
        let tiedA = Meeting(
            title: "Tied A",
            startedAt: base.addingTimeInterval(30))
        let tiedB = Meeting(
            title: "Tied B",
            startedAt: base.addingTimeInterval(30))
        let corrupt = Meeting(
            title: "Corrupt",
            startedAt: base.addingTimeInterval(120))
        let deleted = Meeting(
            title: "Deleted",
            startedAt: base.addingTimeInterval(180))
        for meeting in [older, newer, tiedA, tiedB, corrupt, deleted] {
            try await store.save(meeting)
        }

        let speaker = Speaker(
            meetingID: newer.id,
            label: "S1",
            displayName: "Ana")
        let segment = TranscriptSegment(
            meetingID: newer.id,
            speakerID: speaker.id,
            channel: .system,
            text: "Budget approved",
            startTime: 1,
            endTime: 2)
        try await store.save([speaker])
        try await store.save([segment])
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: newer.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "## General",
            actionItems: [ActionItem(text: "Ship")]))
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: newer.id,
            recipeID: Recipe.standup.id,
            language: "en",
            markdown: "## Standup",
            actionItems: []))

        let corruptSegment = TranscriptSegment(
            meetingID: corrupt.id,
            channel: .system,
            text: "Unreadable channel",
            startTime: 0,
            endTime: 1)
        try await store.save([corruptSegment])
        try await store.database.write { database in
            try database.execute(
                sql: "UPDATE segment SET channel = 'invalid' WHERE id = ?",
                arguments: [corruptSegment.id.uuidString])
        }
        try await store.delete(deleted.id)

        let preparation = try await store.prepareLibraryMarkdownBackupStage(
            in: stagingRoot,
            pagesPerStep: 1,
            mayContinue: { true })
        guard case .ready(let stage) = preparation else {
            return XCTFail("Expected a prepared stage")
        }
        XCTAssertEqual(stage.totalMeetings, 5)

        let later = Meeting(
            title: "Later live mutation",
            startedAt: base.addingTimeInterval(240))
        try await store.save(later)

        var snapshots: [MeetingMarkdownBackupSnapshot] = []
        var failures: [MeetingMarkdownBackupReadFailure] = []
        while let entry = try await stage.next() {
            switch entry {
            case .meeting(let snapshot): snapshots.append(snapshot)
            case .failure(let failure): failures.append(failure)
            }
        }

        let tied = [tiedA, tiedB].sorted {
            $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
        XCTAssertEqual(
            snapshots.map(\.meeting.id),
            [newer.id] + tied.map(\.id) + [older.id])
        let newerSnapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(newerSnapshot.speakers.map(\.displayName), ["Ana"])
        XCTAssertEqual(newerSnapshot.segments.map(\.text), ["Budget approved"])
        XCTAssertEqual(newerSnapshot.summary?.markdown, "## General")
        XCTAssertEqual(newerSnapshot.summary?.actionItems.map(\.text), ["Ship"])
        XCTAssertEqual(newerSnapshot.summaryVersion, 1)
        XCTAssertEqual(failures, [MeetingMarkdownBackupReadFailure(
            meetingID: corrupt.id,
            title: "Corrupt")])

        let workspace = await stage.workspaceURL
        XCTAssertEqual(
            UUID(uuidString: workspace.lastPathComponent),
            stage.id)
        let workspaceAttributes = try FileManager.default.attributesOfItem(
            atPath: workspace.path)
        let databaseAttributes = try FileManager.default.attributesOfItem(
            atPath: workspace.appendingPathComponent("source.sqlite").path)
        let ownerAttributes = try FileManager.default.attributesOfItem(
            atPath: workspace.appendingPathComponent(".owner.lock").path)
        XCTAssertEqual(
            (workspaceAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0,
            0o700)
        XCTAssertEqual(
            (databaseAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0,
            0o600)
        XCTAssertEqual(
            (ownerAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0,
            0o600)
        XCTAssertEqual(
            try stagingRoot.resourceValues(
                forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
            true)

        await stage.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
    }

    func testStageCopySuspendsBetweenSQLitePagesAndRemovesPartialWorkspace() async throws {
        let stagingRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Large", startedAt: Date())
        try await store.save(meeting)
        let payload = String(repeating: "bounded transcript evidence ", count: 512)
        let segments = (0..<128).map { index in
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "\(index) \(payload)",
                startTime: Double(index),
                endTime: Double(index + 1))
        }
        try await store.save(segments)
        let checkpoint = StageCheckpoint(firstAllowedCalls: 1)

        let preparation = try await store.prepareLibraryMarkdownBackupStage(
            in: stagingRoot,
            pagesPerStep: 1,
            mayContinue: { checkpoint.mayContinue() })

        guard case .suspended = preparation else {
            return XCTFail("Expected page-copy suspension")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.isDirectoryKey])
            .filter {
                try $0.resourceValues(
                    forKeys: [.isDirectoryKey]).isDirectory == true
            }
        XCTAssertTrue(leftovers.isEmpty)
        XCTAssertGreaterThanOrEqual(checkpoint.callCount, 2)
    }

    func testCleanupRemovesOnlyAbandonedOwnedWorkspaces() async throws {
        let stagingRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let store = try MeetingStore.inMemory()
        try await store.save(Meeting(title: "Active", startedAt: Date()))
        let preparation = try await store.prepareLibraryMarkdownBackupStage(
            in: stagingRoot,
            pagesPerStep: 1,
            mayContinue: { true })
        guard case .ready(let stage) = preparation else {
            return XCTFail("Expected a prepared stage")
        }
        let activeWorkspace = await stage.workspaceURL

        let abandonedID = UUID()
        let abandonedWorkspace = stagingRoot.appendingPathComponent(
            abandonedID.uuidString.lowercased(),
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: abandonedWorkspace,
            withIntermediateDirectories: false)
        let abandonedOwner = abandonedWorkspace.appendingPathComponent(
            ".owner.lock")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: abandonedOwner.path,
            contents: Data()))

        let malformedWorkspace = stagingRoot.appendingPathComponent(
            "malformed-with-owner",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: malformedWorkspace,
            withIntermediateDirectories: false)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: malformedWorkspace
                .appendingPathComponent(".owner.lock").path,
            contents: Data()))

        let noncanonicalWorkspace = stagingRoot.appendingPathComponent(
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: noncanonicalWorkspace,
            withIntermediateDirectories: false)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: noncanonicalWorkspace
                .appendingPathComponent(".owner.lock").path,
            contents: Data()))

        let legacyWorkspace = stagingRoot.appendingPathComponent(
            "legacy-without-owner",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyWorkspace,
            withIntermediateDirectories: false)

        XCTAssertEqual(
            try MeetingStore.cleanupAbandonedLibraryMarkdownBackupStages(
                in: stagingRoot),
            [abandonedID])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: activeWorkspace.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: abandonedWorkspace.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: malformedWorkspace.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: noncanonicalWorkspace.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: legacyWorkspace.path))

        await stage.close()
    }

    func testCleanupPreservesEveryJournalOwnedStage() async throws {
        let stagingRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let store = try MeetingStore.inMemory()
        try await store.save(Meeting(title: "Source", startedAt: Date()))
        let preparation = try await store.prepareLibraryMarkdownBackupStage(
            in: stagingRoot,
            pagesPerStep: 1,
            mayContinue: { true })
        guard case .ready(let original) = preparation else {
            return XCTFail("Expected a prepared stage")
        }
        let preservedID = UUID()
        let removedID = UUID()
        let preserved = try await cloneStageWorkspace(
            from: original,
            as: preservedID,
            in: stagingRoot)
        let removed = try await cloneStageWorkspace(
            from: original,
            as: removedID,
            in: stagingRoot)

        XCTAssertEqual(
            try MeetingStore.cleanupAbandonedLibraryMarkdownBackupStages(
                in: stagingRoot,
                preserving: [preservedID]),
            [removedID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))

        await original.close()
    }

    func testStageAdoptionResumesAfterExactContentFreeCursor() async throws {
        let stagingRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let store = try MeetingStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_790_100_000)
        let older = Meeting(title: "Older", startedAt: base)
        let newer = Meeting(
            title: "Newer",
            startedAt: base.addingTimeInterval(60))
        try await store.save(older)
        try await store.save(newer)

        let preparation = try await store.prepareLibraryMarkdownBackupStage(
            in: stagingRoot,
            pagesPerStep: 1,
            mayContinue: { true })
        guard case .ready(let original) = preparation else {
            return XCTFail("Expected a prepared stage")
        }
        guard case .meeting(let first)? = try await original.next() else {
            return XCTFail("Expected the newest staged meeting")
        }
        XCTAssertEqual(first.meeting.id, newer.id)
        let currentCheckpoint = try await original.checkpoint()
        let cursor = try XCTUnwrap(currentCheckpoint)
        let persistedCursor = try JSONDecoder().decode(
            MeetingMarkdownBackupStageCursor.self,
            from: JSONEncoder().encode(cursor))
        XCTAssertEqual(persistedCursor, cursor)

        let activeAdoption = try await MeetingStore
            .adoptLibraryMarkdownBackupStage(
                id: original.id,
                cursor: persistedCursor,
                in: stagingRoot)
        guard case .unavailable = activeAdoption else {
            return XCTFail("An active kernel-owned stage must not be adopted")
        }

        let adoptedID = UUID()
        let adoptedWorkspace = try await cloneStageWorkspace(
            from: original,
            as: adoptedID,
            in: stagingRoot)
        let adoption = try await MeetingStore.adoptLibraryMarkdownBackupStage(
            id: adoptedID,
            cursor: persistedCursor,
            in: stagingRoot)
        guard case .ready(let adopted) = adoption else {
            return XCTFail("Expected the abandoned stage clone to be adopted")
        }
        XCTAssertEqual(adopted.totalMeetings, 2)
        guard case .meeting(let resumed)? = try await adopted.next() else {
            return XCTFail("Expected adoption to continue after the cursor")
        }
        XCTAssertEqual(resumed.meeting.id, older.id)
        let resumedCheckpoint = try await adopted.checkpoint()
        XCTAssertEqual(
            resumedCheckpoint?.recordID,
            older.id.rawValue.uuidString)
        let exhaustedEntry = try await adopted.next()
        XCTAssertNil(exhaustedEntry)

        await adopted.close()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: adoptedWorkspace.path))
        await original.close()
    }

    func testAbandonedAdoptedStageCanBeAdoptedAgain() async throws {
        let stagingRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let store = try MeetingStore.inMemory()
        try await store.save(Meeting(title: "Retry", startedAt: Date()))
        let preparation = try await store.prepareLibraryMarkdownBackupStage(
            in: stagingRoot,
            pagesPerStep: 1,
            mayContinue: { true })
        guard case .ready(let original) = preparation else {
            return XCTFail("Expected a prepared stage")
        }
        let adoptedID = UUID()
        let workspace = try await cloneStageWorkspace(
            from: original,
            as: adoptedID,
            in: stagingRoot)
        let firstAdoption = try await MeetingStore
            .adoptLibraryMarkdownBackupStage(
                id: adoptedID,
                cursor: nil,
                in: stagingRoot)
        guard case .ready(let first) = firstAdoption else {
            return XCTFail("Expected first adoption")
        }

        await first.abandon()
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))

        let secondAdoption = try await MeetingStore
            .adoptLibraryMarkdownBackupStage(
                id: adoptedID,
                cursor: nil,
                in: stagingRoot)
        guard case .ready(let second) = secondAdoption else {
            return XCTFail("Expected retry adoption")
        }
        await second.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        await original.close()
    }

    func testStageAdoptionRejectsMismatchedCursorAndSymlinkDatabase() async throws {
        let stagingRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let store = try MeetingStore.inMemory()
        try await store.save(Meeting(
            title: "Planning",
            startedAt: Date(timeIntervalSince1970: 1_790_200_000)))

        let preparation = try await store.prepareLibraryMarkdownBackupStage(
            in: stagingRoot,
            pagesPerStep: 1,
            mayContinue: { true })
        guard case .ready(let original) = preparation else {
            return XCTFail("Expected a prepared stage")
        }
        guard try await original.next() != nil else {
            return XCTFail("Expected one staged meeting")
        }
        let currentCheckpoint = try await original.checkpoint()
        let cursor = try XCTUnwrap(currentCheckpoint)

        let mismatchedID = UUID()
        let mismatchedWorkspace = try await cloneStageWorkspace(
            from: original,
            as: mismatchedID,
            in: stagingRoot)
        await XCTAssertThrowsErrorAsync {
            _ = try await MeetingStore.adoptLibraryMarkdownBackupStage(
                id: mismatchedID,
                cursor: MeetingMarkdownBackupStageCursor(
                    startedAt: cursor.startedAt,
                    recordID: UUID().uuidString),
                in: stagingRoot)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: mismatchedWorkspace.path))

        let symlinkID = UUID()
        let symlinkWorkspace = try await cloneStageWorkspace(
            from: original,
            as: symlinkID,
            in: stagingRoot)
        let symlinkDatabase = symlinkWorkspace.appendingPathComponent(
            "source.sqlite")
        try FileManager.default.removeItem(at: symlinkDatabase)
        let originalWorkspace = await original.workspaceURL
        try FileManager.default.createSymbolicLink(
            at: symlinkDatabase,
            withDestinationURL: originalWorkspace
                .appendingPathComponent("source.sqlite"))
        await XCTAssertThrowsErrorAsync {
            _ = try await MeetingStore.adoptLibraryMarkdownBackupStage(
                id: symlinkID,
                cursor: nil,
                in: stagingRoot)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: symlinkWorkspace.path))

        await original.close()
    }

    private func cloneStageWorkspace(
        from stage: MeetingMarkdownBackupStage,
        as id: UUID,
        in stagingRoot: URL
    ) async throws -> URL {
        let destination = stagingRoot.appendingPathComponent(
            id.uuidString.lowercased(),
            isDirectory: true)
        try FileManager.default.copyItem(
            at: await stage.workspaceURL,
            to: destination)
        return destination
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private final class StageCheckpoint: @unchecked Sendable {
    private let lock = NSLock()
    private let firstAllowedCalls: Int
    private var calls = 0

    init(firstAllowedCalls: Int) {
        self.firstAllowedCalls = firstAllowedCalls
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func mayContinue() -> Bool {
        lock.withLock {
            calls += 1
            return calls <= firstAllowedCalls
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
