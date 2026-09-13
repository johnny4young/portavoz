import ApplicationKit
import Darwin
import Foundation
import XCTest

@testable import portavoz_app

final class PortableSettingsFileTests: XCTestCase {
    func testSelectedFileRoundTripIsPrivateAndReplacesOnlyTheSelectedEntry() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("ajustes-Don’t.json")
        let original = directory.appendingPathComponent("original.json")
        try Data("untouched".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: original)
        let data = Data("Cóndor C++ $1 \\ — don’t".utf8)
        try PortableSettingsFile.write(data, to: destination)
        XCTAssertEqual(try PortableSettingsFile.read(destination), data)
        XCTAssertEqual(try Data(contentsOf: original), Data("untouched".utf8), "do not follow a destination symlink")
        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       [destination.lastPathComponent, original.lastPathComponent])
        try PortableSettingsFile.write(Data(), to: destination)
        XCTAssertEqual(try PortableSettingsFile.read(destination), Data())
    }

    func testReadsRejectSymlinksDirectoriesAndFIFOsBeforeReadingBytes() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.json")
        try Data("{}".utf8).write(to: source)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let pipe = directory.appendingPathComponent("pipe.json")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        for rejected in [directory, link, pipe, directory.appendingPathComponent("missing.json")] {
            XCTAssertThrowsError(try PortableSettingsFile.read(rejected))
        }
    }

    func testExactFileBoundAndRejectedPublicationPreservePreviousFileAndCleanStaging() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("settings.json")
        let maximum = Data(repeating: 65, count: PortableSettingsValidation.maximumFileBytes)
        try PortableSettingsFile.write(maximum, to: destination)
        XCTAssertEqual(try PortableSettingsFile.read(destination), maximum)
        var oversized = maximum
        oversized.append(66)
        XCTAssertThrowsError(try PortableSettingsFile.write(oversized, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), maximum)
        let large = directory.appendingPathComponent("large.json")
        try oversized.write(to: large)
        XCTAssertThrowsError(try PortableSettingsFile.read(large))
        let invalid = directory.appendingPathComponent("directory.json", isDirectory: true)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false)
        XCTAssertThrowsError(try PortableSettingsFile.write(Data("private".utf8), to: invalid))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       ["settings.json", "large.json", "directory.json"])
    }

    @MainActor
    func testCancelledWriterPreservesDestinationAndRemovesPrivateStaging() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("settings.json")
        let original = Data("previous approved file".utf8)
        try original.write(to: destination)
        let task = Task { try PortableSettingsFile.write(Data("do not publish".utf8), to: destination) }
        task.cancel() // Same-actor task cannot begin before this cancellation.
        do {
            try await task.value
            XCTFail("cancelled export must not publish")
        } catch is CancellationError {
            XCTAssertEqual(try Data(contentsOf: destination), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["settings.json"])
        }
    }

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
