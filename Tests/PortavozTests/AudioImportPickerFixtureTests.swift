import AppKit
import Foundation
import XCTest
@testable import portavoz_app

@MainActor
final class AudioImportPickerFixtureTests: XCTestCase {
    func testInitialDirectoryRequiresEveryExplicitFixtureGateWithoutSelectingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let selection = root.appendingPathComponent("selection", isDirectory: true)
        try FileManager.default.createDirectory(at: selection, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let flags = ["-use-temp-store", "-audio-import-ui-fixture", "-audio-import-picker-fixture"]
        for mask in 0..<8 {
            let panel = NSOpenPanel()
            panel.directoryURL = root
            let original = panel.directoryURL
            let arguments = flags.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil }
            AudioImportUITestFixture.configurePicker(panel, arguments: arguments, environment: ["TMPDIR": root.path])
            XCTAssertEqual(panel.directoryURL, mask == 7 ? selection : original)
            XCTAssertTrue(panel.urls.isEmpty, "Preparing navigation is not authority to select or admit audio")
            XCTAssertFalse(panel.isVisible, "The fixture cannot present or confirm a picker")
        }
    }

    func testMissingRelativeRootAndNonDirectorySelectionLeavePanelUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = NSOpenPanel()
        panel.directoryURL = root
        let original = panel.directoryURL
        let flags = ["-use-temp-store", "-audio-import-ui-fixture", "-audio-import-picker-fixture"]
        for environment in [[:], ["TMPDIR": ""], ["TMPDIR": "/"], ["TMPDIR": "relative"], ["TMPDIR": root.path]] {
            AudioImportUITestFixture.configurePicker(panel, arguments: flags, environment: environment)
            XCTAssertEqual(panel.directoryURL, original)
        }
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("selection"))
        AudioImportUITestFixture.configurePicker(panel, arguments: flags, environment: ["TMPDIR": root.path])
        XCTAssertEqual(panel.directoryURL, original)
    }
}
