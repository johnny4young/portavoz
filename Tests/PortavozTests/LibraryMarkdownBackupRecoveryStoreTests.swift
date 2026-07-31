import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

final class LibraryMarkdownBackupRecoveryStoreTests: XCTestCase {
    func testRoundTripsAndAtomicallyReplacesPrivateRecoveryState() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryMarkdownBackupRecoveryStore(root: root)
        let operationID = UUID()
        let publication = recoveryPublication(
            fileName: "Meeting.md",
            includesSourceCursor: true)
        let bookmark = LibraryMarkdownBackupDestinationBookmark(
            data: Data("bookmark".utf8))

        try await store.apply(
            .begin(destinationBookmark: bookmark),
            operationID: operationID)
        try await store.apply(
            .reserve(publication),
            operationID: operationID)
        let initialState = try await store.load(operationID: operationID)
        XCTAssertEqual(initialState, LibraryMarkdownBackupRecoveryState(
            operationID: operationID,
            destinationBookmark: bookmark,
            pendingPublication: publication))

        try await store.apply(
            .complete(publication),
            operationID: operationID)
        let sourceCursor = try XCTUnwrap(publication.sourceCursor)
        try await store.apply(
            .checkpointSource(sourceCursor),
            operationID: operationID)
        try await store.apply(
            .markCompleted,
            operationID: operationID)
        let completedState = try await store.load(operationID: operationID)
        XCTAssertEqual(completedState, LibraryMarkdownBackupRecoveryState(
            operationID: operationID,
            destinationBookmark: bookmark,
            sourceCursor: sourceCursor,
            completedPublications: [publication],
            phase: .completed))

        let attributes = try FileManager.default.attributesOfItem(
            atPath: completedRecoveryFile(
                root: root,
                operationID: operationID,
                sequence: 0).path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: root.path)[
                .posixPermissions
            ] as? NSNumber)?.intValue,
            0o700)
        XCTAssertEqual(
            try root.resourceValues(
                forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
            true)

        try await store.remove(operationID: operationID)
        let removedState = try await store.load(operationID: operationID)
        XCTAssertNil(removedState)
    }

    func testLoadRejectsStateStoredUnderAnotherOperationID() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryMarkdownBackupRecoveryStore(root: root)
        let originalID = UUID()
        let otherID = UUID()
        try await store.apply(
            .begin(destinationBookmark: LibraryMarkdownBackupDestinationBookmark(
                data: Data("bookmark".utf8))),
            operationID: originalID)
        try FileManager.default.copyItem(
            at: recoveryOperation(root: root, operationID: originalID),
            to: recoveryOperation(root: root, operationID: otherID))

        await assertRecoveryStoreThrows {
            _ = try await store.load(operationID: otherID)
        }
    }

    func testCollisionReplacesOnlyPendingRecordAndKeepsCompletedRecordsImmutable()
        async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryMarkdownBackupRecoveryStore(root: root)
        let operationID = UUID()
        let firstAttempt = recoveryPublication(fileName: "Meeting.md")
        let firstPublished = recoveryPublication(fileName: "Meeting 2.md")
        let secondPublished = LibraryMarkdownBackupRecoveryPublication(
            sequence: 1,
            meetingID: MeetingID(),
            fileName: "Second.md",
            sha256: String(repeating: "b", count: 64),
            byteCount: 84)
        try await store.apply(
            .begin(destinationBookmark: LibraryMarkdownBackupDestinationBookmark(
                data: Data("bookmark".utf8))),
            operationID: operationID)

        try await store.apply(.reserve(firstAttempt), operationID: operationID)
        try await store.apply(.reserve(firstPublished), operationID: operationID)
        try await store.apply(.complete(firstPublished), operationID: operationID)
        try await store.apply(.reserve(secondPublished), operationID: operationID)
        try await store.apply(.complete(secondPublished), operationID: operationID)

        let state = try await store.load(operationID: operationID)
        XCTAssertEqual(
            state?.completedPublications,
            [firstPublished, secondPublished])
        XCTAssertNil(state?.pendingPublication)
        let completedFiles = try FileManager.default.contentsOfDirectory(
            at: recoveryOperation(root: root, operationID: operationID)
                .appendingPathComponent("completed", isDirectory: true),
            includingPropertiesForKeys: nil)
        XCTAssertEqual(completedFiles.count, 2)
    }

    func testLoadAndRemoveRejectSymlinkDocuments() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false)
        let operationID = UUID()
        try FileManager.default.createSymbolicLink(
            at: recoveryOperation(root: root, operationID: operationID),
            withDestinationURL: outside)
        let store = AppLibraryMarkdownBackupRecoveryStore(root: root)

        await assertRecoveryStoreThrows {
            _ = try await store.load(operationID: operationID)
        }
        await assertRecoveryStoreThrows {
            try await store.remove(operationID: operationID)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testReserveRejectsDanglingPendingSymlink() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryMarkdownBackupRecoveryStore(root: root)
        let operationID = UUID()
        try await store.apply(
            .begin(destinationBookmark: LibraryMarkdownBackupDestinationBookmark(
                data: Data("bookmark".utf8))),
            operationID: operationID)
        let pending = recoveryOperation(root: root, operationID: operationID)
            .appendingPathComponent("pending.json")
        let missingTarget = root.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(
            at: pending,
            withDestinationURL: missingTarget)

        await assertRecoveryStoreThrows {
            try await store.apply(
                .reserve(recoveryPublication(fileName: "Meeting.md")),
                operationID: operationID)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: missingTarget.path))
    }

    func testLoadRejectsRenamedCompletedSequenceRecord() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryMarkdownBackupRecoveryStore(root: root)
        let operationID = UUID()
        let publication = recoveryPublication(fileName: "Meeting.md")
        try await store.apply(
            .begin(destinationBookmark: LibraryMarkdownBackupDestinationBookmark(
                data: Data("bookmark".utf8))),
            operationID: operationID)
        try await store.apply(.reserve(publication), operationID: operationID)
        try await store.apply(.complete(publication), operationID: operationID)
        try FileManager.default.moveItem(
            at: completedRecoveryFile(
                root: root,
                operationID: operationID,
                sequence: 0),
            to: recoveryOperation(root: root, operationID: operationID)
                .appendingPathComponent("completed", isDirectory: true)
                .appendingPathComponent("renamed.json"))

        await assertRecoveryStoreThrows {
            _ = try await store.load(operationID: operationID)
        }
    }

    func testBookmarkUpdateRejectsEmptyIdentityWithoutCorruptingState()
        async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryMarkdownBackupRecoveryStore(root: root)
        let operationID = UUID()
        let bookmark = LibraryMarkdownBackupDestinationBookmark(
            data: Data("bookmark".utf8))
        try await store.apply(
            .begin(destinationBookmark: bookmark),
            operationID: operationID)

        await assertRecoveryStoreThrows {
            try await store.apply(
                .updateDestinationBookmark(
                    LibraryMarkdownBackupDestinationBookmark(data: Data())),
                operationID: operationID)
        }

        let retainedState = try await store.load(operationID: operationID)
        XCTAssertEqual(retainedState?.destinationBookmark, bookmark)
    }

    func testCompletionRejectsPendingPublication() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryMarkdownBackupRecoveryStore(root: root)
        let operationID = UUID()
        try await store.apply(
            .begin(destinationBookmark: LibraryMarkdownBackupDestinationBookmark(
                data: Data("bookmark".utf8))),
            operationID: operationID)
        try await store.apply(
            .reserve(recoveryPublication(fileName: "Meeting.md")),
            operationID: operationID)

        await assertRecoveryStoreThrows {
            try await store.apply(
                .markCompleted,
                operationID: operationID)
        }

        let retainedState = try await store.load(operationID: operationID)
        XCTAssertEqual(retainedState?.phase, .active)
    }

    func testSourceCheckpointRejectsPendingAndRegressivePositions()
        async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryMarkdownBackupRecoveryStore(root: root)
        let operationID = UUID()
        let publication = recoveryPublication(fileName: "Meeting.md")
        try await store.apply(
            .begin(destinationBookmark: LibraryMarkdownBackupDestinationBookmark(
                data: Data("bookmark".utf8))),
            operationID: operationID)
        try await store.apply(
            .reserve(publication),
            operationID: operationID)

        await assertRecoveryStoreThrows {
            try await store.apply(
                .checkpointSource(backupSourceCursor()),
                operationID: operationID)
        }

        try await store.apply(
            .complete(publication),
            operationID: operationID)
        let first = backupSourceCursor()
        await assertRecoveryStoreThrows {
            try await store.apply(
                .checkpointSource(LibraryMarkdownBackupSourceCursor(
                    startedAt: first.startedAt,
                    recordID: "")),
                operationID: operationID)
        }
        try await store.apply(
            .checkpointSource(first),
            operationID: operationID)
        try await store.apply(
            .checkpointSource(first),
            operationID: operationID)
        let sameTimestampNext = LibraryMarkdownBackupSourceCursor(
            startedAt: first.startedAt,
            recordID: "\(first.recordID)-next")
        try await store.apply(
            .checkpointSource(sameTimestampNext),
            operationID: operationID)
        let olderTimestampNext = LibraryMarkdownBackupSourceCursor(
            startedAt: first.startedAt.addingTimeInterval(-1),
            recordID: "next-source-record")
        try await store.apply(
            .checkpointSource(olderTimestampNext),
            operationID: operationID)
        await assertRecoveryStoreThrows {
            try await store.apply(
                .checkpointSource(first),
                operationID: operationID)
        }

        let retainedState = try await store.load(operationID: operationID)
        XCTAssertEqual(retainedState?.sourceCursor, olderTimestampNext)
    }

    func testReservationRejectsSourceCursorForAnotherMeeting() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryMarkdownBackupRecoveryStore(root: root)
        let operationID = UUID()
        try await store.apply(
            .begin(destinationBookmark: LibraryMarkdownBackupDestinationBookmark(
                data: Data("bookmark".utf8))),
            operationID: operationID)
        let publication = LibraryMarkdownBackupRecoveryPublication(
            sequence: 0,
            meetingID: MeetingID(),
            fileName: "Meeting.md",
            sha256: String(repeating: "a", count: 64),
            byteCount: 42,
            sourceCursor: LibraryMarkdownBackupSourceCursor(
                startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                recordID: MeetingID().rawValue.uuidString))

        await assertRecoveryStoreThrows {
            try await store.apply(
                .reserve(publication),
                operationID: operationID)
        }
        let retainedState = try await store.load(operationID: operationID)
        XCTAssertNil(retainedState?.pendingPublication)
    }

    func testLegacyPublicationWithoutCursorStillDecodes() throws {
        let publication = recoveryPublication(fileName: "Meeting.md")
        let encoded = try JSONEncoder().encode(publication)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["sourceCursor"])

        let decoded = try JSONDecoder().decode(
            LibraryMarkdownBackupRecoveryPublication.self,
            from: encoded)

        XCTAssertEqual(decoded, publication)
        XCTAssertNil(decoded.sourceCursor)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private func recoveryPublication(
    fileName: String,
    includesSourceCursor: Bool = false
) -> LibraryMarkdownBackupRecoveryPublication {
    let meetingID = MeetingID()
    return LibraryMarkdownBackupRecoveryPublication(
        sequence: 0,
        meetingID: meetingID,
        fileName: fileName,
        sha256: String(repeating: "a", count: 64),
        byteCount: 42,
        sourceCursor: includesSourceCursor
            ? LibraryMarkdownBackupSourceCursor(
                startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                recordID: meetingID.rawValue.uuidString)
            : nil)
}

private func backupSourceCursor() -> LibraryMarkdownBackupSourceCursor {
    LibraryMarkdownBackupSourceCursor(
        startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        recordID: "source-record")
}

private func recoveryOperation(
    root: URL,
    operationID: UUID
) -> URL {
    root.appendingPathComponent(
        operationID.uuidString.lowercased(),
        isDirectory: true)
}

private func completedRecoveryFile(
    root: URL,
    operationID: UUID,
    sequence: Int
) -> URL {
    recoveryOperation(root: root, operationID: operationID)
        .appendingPathComponent("completed", isDirectory: true)
        .appendingPathComponent(String(format: "%012d.json", sequence))
}

private func assertRecoveryStoreThrows(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected recovery store operation to throw", file: file, line: line)
    } catch {}
}
