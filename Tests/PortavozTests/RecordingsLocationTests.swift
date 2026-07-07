import Foundation
import XCTest

@testable import StorageKit

final class RecordingsLocationTests: XCTestCase {
    private var workspace: URL!
    private var defaultRoot: URL!
    private var location: RecordingsLocation!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defaultRoot = workspace.appendingPathComponent("support")
        try FileManager.default.createDirectory(
            at: defaultRoot, withIntermediateDirectories: true)
        location = RecordingsLocation(
            defaultRoot: defaultRoot,
            markerURL: defaultRoot.appendingPathComponent("recordings-root.txt"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    private func makeRecording(_ name: String, under root: URL) throws -> URL {
        let directory = root.appendingPathComponent("Audio/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: directory.appendingPathComponent("microphone.wav"))
        return directory
    }

    func testDefaultRootWhenNoMarker() {
        XCTAssertEqual(location.currentRoot(), defaultRoot)
        XCTAssertFalse(location.isCustom)
    }

    func testSetAndReadCustomRoot() throws {
        let custom = workspace.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try location.setRoot(custom)
        XCTAssertEqual(location.currentRoot().path, custom.path)
        XCTAssertTrue(location.isCustom)

        try location.setRoot(nil)
        XCTAssertEqual(location.currentRoot(), defaultRoot)
    }

    func testVanishedCustomRootFallsBackToDefault() throws {
        let gone = workspace.appendingPathComponent("unplugged-disk")
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        try location.setRoot(gone)
        try FileManager.default.removeItem(at: gone)
        XCTAssertEqual(location.currentRoot(), defaultRoot)
    }

    func testResolvePrefersCurrentRootAndFallsBackToDefault() throws {
        let custom = workspace.appendingPathComponent("chosen")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try location.setRoot(custom)

        // Un-migrated meeting: only exists under the default root.
        _ = try makeRecording("OLD", under: defaultRoot)
        XCTAssertEqual(
            location.resolve("Audio/OLD").path,
            defaultRoot.appendingPathComponent("Audio/OLD").path)

        // Migrated meeting: the custom root wins.
        _ = try makeRecording("NEW", under: custom)
        XCTAssertEqual(
            location.resolve("Audio/NEW").path,
            custom.appendingPathComponent("Audio/NEW").path)
    }

    func testMigrateMovesEveryRecording() throws {
        _ = try makeRecording("A", under: defaultRoot)
        _ = try makeRecording("B", under: defaultRoot)
        let custom = workspace.appendingPathComponent("target")

        var reports: [(Int, Int)] = []
        let moved = try location.migrateAudio(from: defaultRoot, to: custom) {
            reports.append(($0, $1))
        }

        XCTAssertEqual(moved, 2)
        XCTAssertEqual(reports.map(\.0), [1, 2])
        for name in ["A", "B"] {
            let target = custom.appendingPathComponent("Audio/\(name)/microphone.wav")
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
            let source = defaultRoot.appendingPathComponent("Audio/\(name)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testMigrateResumesAfterInterruption() throws {
        // "A" already migrated on a previous run (exists at BOTH ends);
        // "B" is still pending.
        let custom = workspace.appendingPathComponent("target")
        _ = try makeRecording("A", under: defaultRoot)
        _ = try makeRecording("A", under: custom)
        _ = try makeRecording("B", under: defaultRoot)

        let moved = try location.migrateAudio(from: defaultRoot, to: custom)

        XCTAssertEqual(moved, 2)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: defaultRoot.appendingPathComponent("Audio/A").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: custom.appendingPathComponent("Audio/B/microphone.wav").path))
    }

    func testMigrateWithoutAudioFolderIsNoOp() throws {
        let custom = workspace.appendingPathComponent("target")
        XCTAssertEqual(try location.migrateAudio(from: defaultRoot, to: custom), 0)
    }
}


final class MeetingAudioLayoutTests: XCTestCase {
    func testPrefersCAFAndFallsBackToLegacyWAV() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNil(MeetingAudioLayout.channelFile(named: "system", in: directory))

        try Data("legacy".utf8).write(to: directory.appendingPathComponent("system.wav"))
        XCTAssertEqual(
            MeetingAudioLayout.channelFile(named: "system", in: directory)?.pathExtension, "wav")

        try Data("current".utf8).write(to: directory.appendingPathComponent("system.caf"))
        XCTAssertEqual(
            MeetingAudioLayout.channelFile(named: "system", in: directory)?.pathExtension, "caf")
    }
}
