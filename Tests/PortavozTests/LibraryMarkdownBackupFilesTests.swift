import ApplicationKit
import Foundation
import XCTest

@testable import portavoz_app

final class LibraryMarkdownBackupFilesTests: XCTestCase {
    func testPublicationIsAtomicAndNeverReplacesExistingFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Meeting.md")
        try Data("old".utf8).write(to: destination)
        let files = AppLibraryMarkdownBackupFiles()

        let collision = try await files.publishMarkdownDocument(
            Data("new".utf8),
            named: "Meeting.md",
            in: directory)

        XCTAssertEqual(collision, .nameCollision)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old")
        XCTAssertTrue(try temporaryFiles(in: directory).isEmpty)

        let published = try await files.publishMarkdownDocument(
            Data("new".utf8),
            named: "Meeting 2.md",
            in: directory)
        XCTAssertEqual(published, .published)
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent("Meeting 2.md"),
                encoding: .utf8),
            "new")
        XCTAssertTrue(try temporaryFiles(in: directory).isEmpty)
    }

    func testInspectionReturnsOnlyVisibleMarkdownNames() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("One.md"))
        try Data().write(to: directory.appendingPathComponent("Two.MD"))
        try Data().write(to: directory.appendingPathComponent("notes.txt"))
        try Data().write(to: directory.appendingPathComponent(".hidden.md"))

        let names = try await AppLibraryMarkdownBackupFiles()
            .existingMarkdownFileNames(in: directory)

        XCTAssertEqual(names, ["One.md", "Two.MD"])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-backup-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        return directory
    }

    private func temporaryFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".portavoz-backup-") }
    }
}
