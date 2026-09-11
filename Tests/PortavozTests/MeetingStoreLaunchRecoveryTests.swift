import Foundation
import PortavozCore
import XCTest

@testable import StorageKit

final class MeetingStoreLaunchRecoveryTests: XCTestCase {
    func testReadOnlyRecoveryCopyPreservesSourceAndPublishesVerifiedPrivateStore() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceURL = workspace.appendingPathComponent("failed.sqlite")
        let destinationRoot = try temporaryDirectory(in: workspace, name: "exports")
        let meeting = Meeting(
            title: "Preserved meeting",
            startedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let source = try MeetingStore(databaseURL: sourceURL)
        defer { try? source.database.close() }
        try await source.save(meeting)
        let sourceBefore = try sourceArtifacts(at: sourceURL)

        let copy = try await MeetingStore.makeReadOnlyRecoveryCopy(
            of: sourceURL,
            in: destinationRoot,
            at: Date(timeIntervalSince1970: 1_790_000_100))

        XCTAssertEqual(try sourceArtifacts(at: sourceURL), sourceBefore)
        XCTAssertTrue(copy.deletingLastPathComponent().standardizedFileURL
            == destinationRoot.standardizedFileURL)
        XCTAssertFalse(copy.lastPathComponent.hasPrefix("."))
        let copiedDatabase = copy.appendingPathComponent("portavoz.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedDatabase.path))
        XCTAssertEqual(try permissions(of: copy), 0o700)
        XCTAssertEqual(try permissions(of: copiedDatabase), 0o600)

        let recovered = try MeetingStore(databaseURL: copiedDatabase)
        let recoveredMeetingIDs = try await recovered.meetings().map(\.id)
        XCTAssertEqual(recoveredMeetingIDs, [meeting.id])
        try recovered.database.close()
    }

    func testRepeatedRecoveryNeverOverwritesAnExistingCopy() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceURL = workspace.appendingPathComponent("failed.sqlite")
        let destinationRoot = try temporaryDirectory(in: workspace, name: "exports")
        let source = try MeetingStore(databaseURL: sourceURL)
        try await source.save(Meeting(title: "One", startedAt: Date()))
        try source.database.close()
        let timestamp = Date(timeIntervalSince1970: 1_790_000_100)

        let first = try await MeetingStore.makeReadOnlyRecoveryCopy(
            of: sourceURL,
            in: destinationRoot,
            at: timestamp)
        let sentinel = first.appendingPathComponent("keep.txt")
        try Data("do not replace".utf8).write(to: sentinel)
        let second = try await MeetingStore.makeReadOnlyRecoveryCopy(
            of: sourceURL,
            in: destinationRoot,
            at: timestamp)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "do not replace")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: second.appendingPathComponent("portavoz.sqlite").path))
    }

    func testCorruptSourceLeavesNoVisibleOrHiddenPartialCopy() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceURL = workspace.appendingPathComponent("corrupt.sqlite")
        try Data("not a sqlite database".utf8).write(to: sourceURL)
        let destinationRoot = try temporaryDirectory(in: workspace, name: "exports")

        do {
            _ = try await MeetingStore.makeReadOnlyRecoveryCopy(
                of: sourceURL,
                in: destinationRoot)
            XCTFail("Expected corrupt SQLite recovery to fail")
        } catch {
            XCTAssertFalse(error is MeetingStoreRecoveryCopyError
                && error as? MeetingStoreRecoveryCopyError == .destinationUnavailable)
        }

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: destinationRoot,
                includingPropertiesForKeys: nil),
            [])
    }

    func testMissingSourceAndNonDirectoryDestinationFailClosed() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let missing = workspace.appendingPathComponent("missing.sqlite")

        await XCTAssertThrowsErrorAsync(
            try await MeetingStore.makeReadOnlyRecoveryCopy(
                of: missing,
                in: workspace)) { error in
            XCTAssertEqual(
                error as? MeetingStoreRecoveryCopyError,
                .sourceUnavailable)
        }

        let sourceURL = workspace.appendingPathComponent("source.sqlite")
        let source = try MeetingStore(databaseURL: sourceURL)
        try source.database.close()
        let fileDestination = workspace.appendingPathComponent("file")
        try Data().write(to: fileDestination)
        await XCTAssertThrowsErrorAsync(
            try await MeetingStore.makeReadOnlyRecoveryCopy(
                of: sourceURL,
                in: fileDestination)) { error in
            XCTAssertEqual(
                error as? MeetingStoreRecoveryCopyError,
                .destinationUnavailable)
        }
    }

    private func temporaryDirectory(
        in root: URL = FileManager.default.temporaryDirectory,
        name: String = "PortavozLaunchRecovery-\(UUID().uuidString)"
    ) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return url
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func sourceArtifacts(at sourceURL: URL) throws -> [String: Data] {
        let prefix = sourceURL.lastPathComponent
        let siblings = try FileManager.default.contentsOfDirectory(
            at: sourceURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: siblings
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (any Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
