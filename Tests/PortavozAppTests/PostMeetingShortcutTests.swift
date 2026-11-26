import Foundation
import XCTest
@testable import portavoz_app

final class PostMeetingShortcutTests: XCTestCase {
    func testRunWritesOwnerOnlyFileAndCleansUpAfterCompletion() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-shortcut-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var observedURL: URL?
        var observedPermissions: Int?
        var observedContent: String?
        var completionHandler: (@Sendable () -> Void)?

        PostMeetingShortcut.run(
            shortcutName: "Archive Meeting",
            markdown: "# Meeting\nPrivate summary",
            temporaryDirectory: tempRoot
        ) { inputURL, onComplete in
            observedURL = inputURL
            let attrs = try FileManager.default.attributesOfItem(atPath: inputURL.path)
            observedPermissions = (attrs[.posixPermissions] as? NSNumber)?.intValue
            observedContent = try String(contentsOf: inputURL, encoding: .utf8)
            completionHandler = onComplete
        }

        let createdURL = try XCTUnwrap(observedURL)
        XCTAssertEqual(observedPermissions, 0o600)
        XCTAssertEqual(observedContent, "# Meeting\nPrivate summary")
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdURL.path))

        completionHandler?()
        XCTAssertFalse(FileManager.default.fileExists(atPath: createdURL.path))
    }

    func testRunCleansUpTemporaryFileWhenLaunchFails() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-shortcut-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        struct LaunchFailure: Error {}
        var observedURL: URL?

        PostMeetingShortcut.run(
            shortcutName: "Broken Shortcut",
            markdown: "Confidential notes",
            temporaryDirectory: tempRoot
        ) { inputURL, _ in
            observedURL = inputURL
            throw LaunchFailure()
        }

        let createdURL = try XCTUnwrap(observedURL)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: createdURL.path),
            "temporary meeting markdown must be deleted when shortcuts launch fails")
    }
}
