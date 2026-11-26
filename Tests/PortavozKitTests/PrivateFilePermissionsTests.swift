import AudioCaptureKit
import Foundation
@testable import StorageKit
import XCTest

final class PrivateFilePermissionsTests: XCTestCase {
    func testMeetingStoreCreatesOwnerOnlyDirectoryAndDatabase() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-perms-db-\(UUID().uuidString)")
        let dbDir = tempRoot.appendingPathComponent("nested")
        let dbURL = dbDir.appendingPathComponent("portavoz.sqlite")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        _ = try MeetingStore(databaseURL: dbURL)

        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dbDir.path)
        let dbAttrs = try FileManager.default.attributesOfItem(atPath: dbURL.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((dbAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testMeetingStoreRestrictsExistingWorldReadableDatabase() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-perms-existing-\(UUID().uuidString)")
        let dbURL = tempRoot.appendingPathComponent("portavoz.sqlite")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        _ = try MeetingStore(databaseURL: dbURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dbURL.path)

        _ = try MeetingStore(databaseURL: dbURL)

        let dbAttrs = try FileManager.default.attributesOfItem(atPath: dbURL.path)
        XCTAssertEqual((dbAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testMeetingStoreTightensItsOwnExistingFolderButNotACallersFolder() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-perms-parent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let owned = tempRoot.appendingPathComponent("owned")
        let shared = tempRoot.appendingPathComponent("shared")
        for folder in [owned, shared] {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }

        _ = try MeetingStore(
            databaseURL: owned.appendingPathComponent("portavoz.sqlite"), ownsParentDirectory: true)
        _ = try MeetingStore(databaseURL: shared.appendingPathComponent("portavoz.sqlite"))

        func mode(_ url: URL) throws -> Int? {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        }
        XCTAssertEqual(try mode(owned), 0o700)
        XCTAssertEqual(try mode(shared), 0o755)
    }

    func testCaptureFileWriterCreatesOwnerOnlyAudioFile() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-perms-caf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("microphone.caf")
        let writer = try CaptureFileWriter(url: fileURL, sampleRate: 16_000)
        try writer.append([0.1, -0.1, 0.05])

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
