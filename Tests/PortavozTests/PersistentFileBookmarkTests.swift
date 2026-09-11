import Foundation
import PlatformKit
import XCTest

final class PersistentFileBookmarkTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    func testRoundTripPreservesDirectoryIdentity() throws {
        let directory = workspace.appendingPathComponent(
            "backup",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let bookmarks = PersistentFileBookmark()

        let data = try bookmarks.make(for: directory)
        let resolution = try bookmarks.resolve(data)

        XCTAssertEqual(
            resolution.url.standardizedFileURL,
            directory.standardizedFileURL)
        XCTAssertEqual(resolution.bookmarkData, data)
        XCTAssertFalse(resolution.wasStale)
    }

    func testResolutionFollowsRenamedDirectory() throws {
        let original = workspace.appendingPathComponent(
            "original",
            isDirectory: true)
        let renamed = workspace.appendingPathComponent(
            "renamed",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: original,
            withIntermediateDirectories: true)
        let bookmarks = PersistentFileBookmark()
        let data = try bookmarks.make(for: original)

        try FileManager.default.moveItem(at: original, to: renamed)
        let resolution = try bookmarks.resolve(data)

        XCTAssertEqual(
            resolution.url.standardizedFileURL,
            renamed.standardizedFileURL)
    }

    func testCreationRejectsFilesAndMissingDirectories() throws {
        let file = workspace.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        let missing = workspace.appendingPathComponent(
            "missing",
            isDirectory: true)
        let bookmarks = PersistentFileBookmark()

        for invalidURL in [file, missing] {
            XCTAssertThrowsError(try bookmarks.make(for: invalidURL)) { error in
                XCTAssertEqual(
                    error as? PersistentFileBookmarkError,
                    .notDirectory)
            }
        }
    }
}
