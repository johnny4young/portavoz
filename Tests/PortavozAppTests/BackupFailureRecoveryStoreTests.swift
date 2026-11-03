import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

final class BackupFailureRecoveryStoreTests: XCTestCase {
    func testFailureRoundTripsPrivatelyAndExactRetryIsIdempotent()
        async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryMarkdownBackupRecoveryStore(root: root)
        let operationID = UUID()
        let meetingID = MeetingID()
        let cursor = sourceCursor(meetingID: meetingID)
        let failure = LibraryMarkdownBackupRecoveryFailure(
            sequence: 0,
            sourceCursor: cursor,
            meetingID: meetingID,
            title: "Unreadable meeting",
            stage: .document)
        try await begin(store, operationID: operationID)

        try await store.apply(
            .recordFailure(failure),
            operationID: operationID)
        try await store.apply(
            .recordFailure(failure),
            operationID: operationID)
        try await store.apply(
            .checkpointSource(cursor),
            operationID: operationID)

        let state = try await store.load(operationID: operationID)
        XCTAssertEqual(state?.failures, [failure])
        XCTAssertEqual(state?.sourceCursor, cursor)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: failureFile(
                root: root,
                operationID: operationID,
                sequence: 0).path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)
    }

    func testFailureRejectsPendingAndMismatchedSourceIdentity()
        async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryMarkdownBackupRecoveryStore(root: root)
        let operationID = UUID()
        let publication = recoveryPublication()
        try await begin(store, operationID: operationID)
        try await store.apply(
            .reserve(publication),
            operationID: operationID)
        let cursor = try XCTUnwrap(publication.sourceCursor)
        let failure = recoveryFailure(
            meetingID: publication.meetingID,
            cursor: cursor)

        await assertRecoveryFailure {
            try await store.apply(
                .recordFailure(failure),
                operationID: operationID)
        }
        try await store.apply(
            .clearReservation,
            operationID: operationID)
        let mismatched = recoveryFailure(
            meetingID: publication.meetingID,
            cursor: sourceCursor(meetingID: MeetingID()))
        await assertRecoveryFailure {
            try await store.apply(
                .recordFailure(mismatched),
                operationID: operationID)
        }

        let state = try await store.load(operationID: operationID)
        XCTAssertTrue(state?.failures.isEmpty == true)
    }

    func testFailureRejectsMalformedAndNoncontiguousEvidence()
        async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryMarkdownBackupRecoveryStore(root: root)
        let operationID = UUID()
        let meetingID = MeetingID()
        let cursor = sourceCursor(meetingID: meetingID)
        try await begin(store, operationID: operationID)
        let invalidFailures = [
            recoveryFailure(
                sequence: 1,
                meetingID: meetingID,
                cursor: cursor),
            LibraryMarkdownBackupRecoveryFailure(
                sequence: 0,
                sourceCursor: cursor,
                meetingID: nil,
                title: "Missing identity",
                stage: .publication),
            LibraryMarkdownBackupRecoveryFailure(
                sequence: 0,
                sourceCursor: cursor,
                meetingID: nil,
                title: String(repeating: "a", count: 4_097),
                stage: .source)
        ]

        for failure in invalidFailures {
            await assertRecoveryFailure {
                try await store.apply(
                    .recordFailure(failure),
                    operationID: operationID)
            }
        }

        let state = try await store.load(operationID: operationID)
        XCTAssertTrue(state?.failures.isEmpty == true)
    }

    func testLegacyMetadataWithoutFailureDirectoryStillLoads() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryMarkdownBackupRecoveryStore(root: root)
        let operationID = UUID()
        try await begin(store, operationID: operationID)
        try downgradeMetadata(root: root, operationID: operationID)
        try FileManager.default.removeItem(
            at: failuresDirectory(root: root, operationID: operationID))

        let state = try await store.load(operationID: operationID)

        XCTAssertTrue(state?.failures.isEmpty == true)
    }

    func testLegacyMetadataRejectsFailureRecords() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryMarkdownBackupRecoveryStore(root: root)
        let operationID = UUID()
        try await begin(store, operationID: operationID)
        try downgradeMetadata(root: root, operationID: operationID)
        try Data("{}".utf8).write(
            to: failureFile(
                root: root,
                operationID: operationID,
                sequence: 0))

        await assertRecoveryFailure {
            _ = try await store.load(operationID: operationID)
        }
    }

    func testCurrentMetadataRejectsMissingFailureDirectory() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryMarkdownBackupRecoveryStore(root: root)
        let operationID = UUID()
        try await begin(store, operationID: operationID)
        try FileManager.default.removeItem(
            at: failuresDirectory(root: root, operationID: operationID))

        await assertRecoveryFailure {
            _ = try await store.load(operationID: operationID)
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private func begin(
    _ store: AppLibraryMarkdownBackupRecoveryStore,
    operationID: UUID
) async throws {
    try await store.apply(
        .begin(destinationBookmark: LibraryMarkdownBackupDestinationBookmark(
            data: Data("bookmark".utf8))),
        operationID: operationID)
}

private func recoveryPublication()
    -> LibraryMarkdownBackupRecoveryPublication {
    let meetingID = MeetingID()
    return LibraryMarkdownBackupRecoveryPublication(
        sequence: 0,
        meetingID: meetingID,
        fileName: "Meeting.md",
        sha256: String(repeating: "a", count: 64),
        byteCount: 10,
        sourceCursor: sourceCursor(meetingID: meetingID))
}

private func recoveryFailure(
    sequence: Int = 0,
    meetingID: MeetingID,
    cursor: LibraryMarkdownBackupSourceCursor
) -> LibraryMarkdownBackupRecoveryFailure {
    LibraryMarkdownBackupRecoveryFailure(
        sequence: sequence,
        sourceCursor: cursor,
        meetingID: meetingID,
        title: "Unreadable",
        stage: .document)
}

private func sourceCursor(
    meetingID: MeetingID
) -> LibraryMarkdownBackupSourceCursor {
    LibraryMarkdownBackupSourceCursor(
        startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        recordID: meetingID.rawValue.uuidString)
}

private func operationDirectory(root: URL, operationID: UUID) -> URL {
    root.appendingPathComponent(
        operationID.uuidString.lowercased(),
        isDirectory: true)
}

private func metadataFile(root: URL, operationID: UUID) -> URL {
    operationDirectory(root: root, operationID: operationID)
        .appendingPathComponent("metadata.json")
}

private func failuresDirectory(root: URL, operationID: UUID) -> URL {
    operationDirectory(root: root, operationID: operationID)
        .appendingPathComponent("failures", isDirectory: true)
}

private func failureFile(
    root: URL,
    operationID: UUID,
    sequence: Int
) -> URL {
    failuresDirectory(root: root, operationID: operationID)
        .appendingPathComponent(String(format: "%012d.json", sequence))
}

private func downgradeMetadata(root: URL, operationID: UUID) throws {
    let metadata = metadataFile(root: root, operationID: operationID)
    let data = try Data(contentsOf: metadata)
    var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["version"] = 1
    try JSONSerialization.data(withJSONObject: object)
        .write(to: metadata, options: .atomic)
}

private func assertRecoveryFailure(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected recovery-store failure", file: file, line: line)
    } catch {
        // Expected.
    }
}
