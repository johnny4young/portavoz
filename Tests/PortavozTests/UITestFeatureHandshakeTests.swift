import Foundation
import XCTest
@testable import portavoz_app

final class UITestFeatureHandshakeTests: XCTestCase {
    func testSignalPathUsesExplicitLaunchTemporaryDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let signal = root.appendingPathComponent(
            "portavoz-uitest-ask-ready-\(UUID().uuidString)")

        let validated = try UITestFeatureHandshake.validatedSignalURL(
            path: signal.path,
            processTemporaryPath: root.path + "/")

        XCTAssertEqual(validated, signal.standardizedFileURL)
    }

    func testSignalPathRejectsNonDirectOrForeignChildren() throws {
        let root = try makeRoot()
        let foreignRoot = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: foreignRoot)
        }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true)

        for signal in [
            nested.appendingPathComponent("portavoz-uitest-nested"),
            foreignRoot.appendingPathComponent("portavoz-uitest-foreign"),
            root.appendingPathComponent("unscoped-signal"),
        ] {
            XCTAssertThrowsError(try UITestFeatureHandshake.validatedSignalURL(
                path: signal.path,
                processTemporaryPath: root.path))
        }
    }

    func testSignalPathRejectsMissingLaunchTemporaryDirectory() {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-uitest-missing-\(UUID().uuidString)")
        let signal = missingRoot.appendingPathComponent("portavoz-uitest-ready")

        XCTAssertThrowsError(try UITestFeatureHandshake.validatedSignalURL(
            path: signal.path,
            processTemporaryPath: missingRoot.path))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-uitest-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        return root
    }
}
