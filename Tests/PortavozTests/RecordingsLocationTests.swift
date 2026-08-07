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

    /// Defence in depth behind `ManageRecordingStorage`'s activity gate: the
    /// cross-volume branch copies and then deletes the source, so a live
    /// meeting's directory must never be enumerated even if a caller forgets
    /// to check. Leaving it in place keeps the open writers valid.
    func testMigrateLeavesReservedRecordingsWhereTheirWritersHoldThem() throws {
        _ = try makeRecording("live", under: defaultRoot)
        _ = try makeRecording("finished", under: defaultRoot)
        let custom = workspace.appendingPathComponent("target")

        let moved = try location.migrateAudio(
            from: defaultRoot,
            to: custom,
            skipping: ["live"])

        XCTAssertEqual(moved, 1, "only the finished meeting moves")
        let manager = FileManager.default
        XCTAssertTrue(manager.fileExists(
            atPath: custom.appendingPathComponent("Audio/finished/microphone.wav").path))
        XCTAssertFalse(manager.fileExists(
            atPath: defaultRoot.appendingPathComponent("Audio/finished").path))
        // The live one is untouched at BOTH ends: not copied, not unlinked.
        XCTAssertTrue(manager.fileExists(
            atPath: defaultRoot.appendingPathComponent("Audio/live/microphone.wav").path))
        XCTAssertFalse(manager.fileExists(
            atPath: custom.appendingPathComponent("Audio/live").path))
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

    /// The caller only persists the new root once `migrateAudio` returns, so a
    /// half-done migration would leave recordings under a folder no root points
    /// at — reachable from neither `currentRoot()` nor `defaultRoot`. A failure
    /// must therefore mean nothing happened.
    func testAFailedMigrationPutsBackEverythingItMoved() throws {
        let custom = workspace.appendingPathComponent("target")
        _ = try makeRecording("A", under: defaultRoot)
        _ = try makeRecording("B", under: defaultRoot)
        // A dangling symlink at B's destination: invisible to fileExists, so
        // it is not mistaken for an already-migrated directory, and fatal to
        // both the rename and the cross-volume copy.
        let targetAudio = custom.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(
            at: targetAudio, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: targetAudio.appendingPathComponent("B"),
            withDestinationURL: workspace.appendingPathComponent("nowhere"))

        XCTAssertThrowsError(try location.migrateAudio(from: defaultRoot, to: custom))

        for name in ["A", "B"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: defaultRoot
                    .appendingPathComponent("Audio/\(name)/microphone.wav").path),
                "\(name) must still be reachable from the unchanged root")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: targetAudio.appendingPathComponent("A").path),
            "nothing this run moved may be left behind")
    }

    /// The resume branch drops its source with `try?`, so a source directory
    /// that still exists may be a *partial* leftover. Rolling back must never
    /// delete the complete destination copy on the strength of the source
    /// merely existing — that would destroy audio the pre-rollback code kept.
    func testRollbackNeverDeletesACompleteCopyForAPartialSource() throws {
        let manager = FileManager.default
        let custom = workspace.appendingPathComponent("target")
        let sourceA = try makeRecording("A", under: defaultRoot)
        _ = try makeRecording("A", under: custom)
        _ = try makeRecording("B", under: defaultRoot)
        // Only the destination copy of "A" has the system channel; the source
        // is missing it, exactly as a half-finished removal would leave it.
        try Data("wav".utf8).write(
            to: custom.appendingPathComponent("Audio/A/system.wav"))
        // Make the source's own removal fail so "A" takes the resume branch and
        // is still counted as moved: a read-only subdirectory cannot be emptied.
        let locked = sourceA.appendingPathComponent("locked", isDirectory: true)
        try manager.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("held.wav"))
        defer {
            try? manager.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }
        try manager.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: locked.path)
        try manager.createSymbolicLink(
            at: custom.appendingPathComponent("Audio/B"),
            withDestinationURL: workspace.appendingPathComponent("nowhere"))

        XCTAssertThrowsError(try location.migrateAudio(from: defaultRoot, to: custom))

        // The system channel existed in exactly one place. Wherever rollback
        // left it, it must still exist somewhere.
        let survived = manager.fileExists(
            atPath: sourceA.appendingPathComponent("system.wav").path)
            || manager.fileExists(
                atPath: custom.appendingPathComponent("Audio/A/system.wav").path)
        XCTAssertTrue(
            survived,
            "the only copy of this channel was deleted during rollback")
    }

    /// The failing entry's hidden cross-volume temp is a full copy of that
    /// meeting's audio. Leaving it behind would contradict "nothing happened",
    /// and a later resume could not tell it from a finished directory.
    func testAFailedMigrationLeavesNoHiddenPartialCopy() throws {
        let custom = workspace.appendingPathComponent("target")
        _ = try makeRecording("B", under: defaultRoot)
        let targetAudio = custom.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(
            at: targetAudio, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: targetAudio.appendingPathComponent("B"),
            withDestinationURL: workspace.appendingPathComponent("nowhere"))

        XCTAssertThrowsError(try location.migrateAudio(from: defaultRoot, to: custom))

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: targetAudio.appendingPathComponent(".partial-B").path),
            "no hidden copy of B is left in the destination")
    }

    /// When even the undo fails, the user is told how much is where — without
    /// naming meetings, which would put library content in an error message.
    func testAMigrationThatCannotUndoItselfReportsWhatItStranded() throws {
        let custom = workspace.appendingPathComponent("target")
        _ = try makeRecording("A", under: defaultRoot)
        _ = try makeRecording("A", under: custom)
        _ = try makeRecording("B", under: defaultRoot)
        let targetAudio = custom.appendingPathComponent("Audio", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: targetAudio.path)
        }
        // Read-only destination: A still counts as migrated (its source is just
        // dropped), B cannot land, and A cannot be moved back out either.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: targetAudio.path)

        XCTAssertThrowsError(
            try location.migrateAudio(from: defaultRoot, to: custom)
        ) { error in
            guard case RecordingsMigrationError.stranded(let count, let at, _) =
                error
            else { return XCTFail("expected a stranding report, got \(error)") }
            XCTAssertEqual(count, 1)
            XCTAssertEqual(at.lastPathComponent, "Audio")
            XCTAssertFalse(
                "\(error)".contains("microphone"),
                "the report names a folder and a count, not library content")
        }
    }

    func testMigrateWithoutAudioFolderIsNoOp() throws {
        let custom = workspace.appendingPathComponent("target")
        XCTAssertEqual(try location.migrateAudio(from: defaultRoot, to: custom), 0)
    }

    func testMigrateToSameRootPreservesEveryRecording() throws {
        let recording = try makeRecording("A", under: defaultRoot)
        var reports: [(Int, Int)] = []

        let moved = try location.migrateAudio(
            from: defaultRoot,
            to: defaultRoot.appendingPathComponent("nested/..").standardizedFileURL
        ) {
            reports.append(($0, $1))
        }

        XCTAssertEqual(moved, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path))
        XCTAssertTrue(reports.isEmpty)
    }

    func testMigrateToSymlinkedSameRootPreservesEveryRecording() throws {
        let recording = try makeRecording("A", under: defaultRoot)
        let alias = workspace.appendingPathComponent("recordings-alias")
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: defaultRoot)

        XCTAssertEqual(try location.migrateAudio(from: defaultRoot, to: alias), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path))
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
