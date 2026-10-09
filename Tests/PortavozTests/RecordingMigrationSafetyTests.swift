import Foundation
import XCTest

@testable import StorageKit

final class RecordingMigrationSafetyTests: XCTestCase {
    private let manager = FileManager.default

    func testConflictingDestinationPreservesBothCopiesAndRollsBackEarlierMove() throws {
        for shape in ["empty", "file", "different-bytes", "symlink", "dangling", "hidden", "nested-symlink"] {
            let workspace = try temporaryDirectory()
            defer { try? manager.removeItem(at: workspace) }
            let origin = workspace.appendingPathComponent("origin")
            let destination = workspace.appendingPathComponent("destination")
            _ = try recording("A", under: origin)
            let source = try recording("B", under: origin)
            let target = destination.appendingPathComponent("Audio/B")
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch shape {
            case "file":
                try Data("unrelated".utf8).write(to: target)
            case "symlink", "dangling":
                let unrelated = workspace.appendingPathComponent("unrelated")
                if shape == "symlink" {
                    try manager.createDirectory(at: unrelated, withIntermediateDirectories: true)
                }
                try manager.createSymbolicLink(at: target, withDestinationURL: unrelated)
            default:
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
                if shape != "empty" {
                    try Data((shape == "different-bytes" ? "different" : "audio").utf8)
                        .write(to: target.appendingPathComponent("microphone.wav"))
                }
                if shape == "hidden" {
                    try Data("must survive".utf8).write(to: source.appendingPathComponent(".metadata"))
                }
                if shape == "nested-symlink" {
                    for directory in [source, target] {
                        try manager.createSymbolicLink(
                            at: directory.appendingPathComponent("linked"), withDestinationURL: workspace)
                    }
                }
            }
            let priorStage = destination.appendingPathComponent("Audio/.partial-B")
            try manager.createDirectory(at: priorStage, withIntermediateDirectories: true)
            let retainedRecovery = priorStage.appendingPathComponent("recovery.wav")
            try Data("prior recovery".utf8).write(to: retainedRecovery)
            let location = RecordingsLocation(defaultRoot: origin, markerURL: origin.appendingPathComponent("root.txt"))
            XCTAssertThrowsError(try location.migrateRoot(to: destination), shape)
            for name in ["A", "B"] {
                XCTAssertEqual(try Data(contentsOf: origin.appendingPathComponent("Audio/\(name)/microphone.wav")),
                               Data("audio".utf8), shape)
            }
            XCTAssertNotNil(try manager.attributesOfItem(atPath: target.path)[.type], shape)
            XCTAssertEqual(try Data(contentsOf: retainedRecovery), Data("prior recovery".utf8), shape)
            XCTAssertFalse(manager.fileExists(atPath: destination.appendingPathComponent("Audio/A").path), shape)
            if shape == "different-bytes" {
                XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("microphone.wav")),
                               Data("different".utf8))
            }
        }
    }

    func testActualMarkerWriteFailureRestoresResolvableAudio() throws {
        let workspace = try temporaryDirectory()
        defer { try? manager.removeItem(at: workspace) }
        let origin = workspace.appendingPathComponent("origin")
        _ = try recording("A", under: origin)
        let marker = origin.appendingPathComponent("root.txt")
        try manager.createDirectory(at: marker, withIntermediateDirectories: true)
        try Data("block replacement".utf8).write(to: marker.appendingPathComponent("child"))
        let location = RecordingsLocation(defaultRoot: origin, markerURL: marker)
        let destination = workspace.appendingPathComponent("destination")

        XCTAssertThrowsError(try location.migrateRoot(to: destination))
        XCTAssertEqual(try Data(contentsOf: location.resolve("Audio/A/microphone.wav")), Data("audio".utf8))
        XCTAssertFalse(manager.fileExists(atPath: destination.appendingPathComponent("Audio/A").path))
    }

    func testMarkerCommitFailureFromCustomRootPreservesBothExistingCopies() throws {
        for resetToDefault in [false, true] {
            let workspace = try temporaryDirectory()
            defer { try? manager.removeItem(at: workspace) }
            let defaultRoot = workspace.appendingPathComponent("default")
            let origin = workspace.appendingPathComponent("custom-origin")
            let destination = resetToDefault ? defaultRoot : workspace.appendingPathComponent("custom-target")
            try manager.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
            _ = try recording("A", under: origin)
            _ = try recording("B", under: origin)
            _ = try recording("B", under: destination)
            _ = try recording("unrelated", under: destination)
            let location = RecordingsLocation(defaultRoot: defaultRoot, markerURL: defaultRoot.appendingPathComponent("root.txt"))
            try location.setRoot(origin)
            let markerBefore = try Data(contentsOf: location.markerURL)
            XCTAssertThrowsError(try location.performMigration(
                from: origin, to: destination, commitRoot: { throw MarkerFailure.failed }))
            XCTAssertEqual(try Data(contentsOf: location.markerURL), markerBefore)
            XCTAssertEqual(location.currentRoot().path, origin.path)
            for name in ["A", "B"] {
                XCTAssertEqual(try Data(contentsOf: location.resolve("Audio/\(name)/microphone.wav")), Data("audio".utf8))
            }
            XCTAssertFalse(manager.fileExists(atPath: destination.appendingPathComponent("Audio/A").path))
            for name in ["B", "unrelated"] {
                XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Audio/\(name)/microphone.wav")),
                               Data("audio".utf8))
            }
        }
    }

    func testSuccessfulCustomMoveAndResetPublishTheMarker() throws {
        let workspace = try temporaryDirectory()
        defer { try? manager.removeItem(at: workspace) }
        let origin = workspace.appendingPathComponent("origin")
        let destination = workspace.appendingPathComponent("destination")
        _ = try recording("A", under: origin)
        let location = RecordingsLocation(defaultRoot: origin, markerURL: origin.appendingPathComponent("root.txt"))
        XCTAssertEqual(try location.migrateRoot(to: destination), 1)
        XCTAssertEqual(location.currentRoot().path, destination.path)
        XCTAssertEqual(try Data(contentsOf: location.resolve("Audio/A/microphone.wav")), Data("audio".utf8))
        XCTAssertEqual(try location.migrateRoot(to: nil), 1)
        XCTAssertEqual(location.currentRoot().path, origin.path)
        XCTAssertFalse(manager.fileExists(atPath: location.markerURL.path))
        XCTAssertEqual(try Data(contentsOf: location.resolve("Audio/A/microphone.wav")), Data("audio".utf8))
    }

    func testResetDoesNotRecursivelyDeleteMalformedMarker() throws {
        let workspace = try temporaryDirectory()
        defer { try? manager.removeItem(at: workspace) }
        let marker = workspace.appendingPathComponent("root.txt")
        try manager.createDirectory(at: marker, withIntermediateDirectories: true)
        let child = marker.appendingPathComponent("unrelated")
        try Data("keep".utf8).write(to: child)
        let location = RecordingsLocation(defaultRoot: workspace, markerURL: marker)
        XCTAssertThrowsError(try location.setRoot(nil))
        XCTAssertEqual(try Data(contentsOf: child), Data("keep".utf8))
    }

    func testEmptyRootSelectionCreatesAResolvableDestination() throws {
        let workspace = try temporaryDirectory()
        defer { try? manager.removeItem(at: workspace) }
        let location = RecordingsLocation(defaultRoot: workspace, markerURL: workspace.appendingPathComponent("root.txt"))
        let destination = workspace.appendingPathComponent("empty")
        XCTAssertEqual(try location.migrateRoot(to: destination), 0)
        XCTAssertEqual(location.currentRoot().path, destination.path)
    }

    func testAudioDirectoryAliasNeverDeletesTheOnlyCopy() throws {
        let workspace = try temporaryDirectory()
        defer { try? manager.removeItem(at: workspace) }
        let origin = workspace.appendingPathComponent("origin")
        _ = try recording("A", under: origin)
        let destination = workspace.appendingPathComponent("alias-root")
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: destination.appendingPathComponent("Audio"),
                                       withDestinationURL: origin.appendingPathComponent("Audio"))
        let location = RecordingsLocation(defaultRoot: origin, markerURL: origin.appendingPathComponent("root.txt"))
        XCTAssertEqual(try location.migrateRoot(to: destination), 0)
        XCTAssertEqual(try Data(contentsOf: location.resolve("Audio/A/microphone.wav")), Data("audio".utf8))
        XCTAssertEqual(try Data(contentsOf: origin.appendingPathComponent("Audio/A/microphone.wav")), Data("audio".utf8))
    }

    func testDuplicateMutationDuringProgressCannotDeleteTheOriginal() throws {
        let workspace = try temporaryDirectory()
        defer { try? manager.removeItem(at: workspace) }
        let origin = workspace.appendingPathComponent("origin")
        let destination = workspace.appendingPathComponent("destination")
        _ = try recording("A", under: origin)
        _ = try recording("A", under: destination)
        _ = try recording("B", under: origin)
        let target = destination.appendingPathComponent("Audio/A/microphone.wav")
        let location = RecordingsLocation(defaultRoot: origin, markerURL: origin.appendingPathComponent("root.txt"))
        XCTAssertThrowsError(try location.migrateRoot(to: destination) { completed, _ in
            if completed == 2 { try? Data("changed".utf8).write(to: target) }
        })
        XCTAssertEqual(try Data(contentsOf: origin.appendingPathComponent("Audio/A/microphone.wav")), Data("audio".utf8))
        XCTAssertEqual(try Data(contentsOf: target), Data("changed".utf8))
        XCTAssertEqual(try Data(contentsOf: location.resolve("Audio/B/microphone.wav")), Data("audio".utf8))
        XCTAssertEqual(location.currentRoot().path, origin.path)
    }

    func testReservedRecordingPreventsCustomRootPublication() throws {
        let workspace = try temporaryDirectory()
        defer { try? manager.removeItem(at: workspace) }
        let origin = workspace.appendingPathComponent("custom-origin")
        _ = try recording("live", under: origin)
        let location = RecordingsLocation(defaultRoot: workspace, markerURL: workspace.appendingPathComponent("root.txt"))
        try location.setRoot(origin)
        XCTAssertThrowsError(try location.migrateRoot(to: nil, skipping: ["live"]))
        XCTAssertEqual(location.currentRoot().path, origin.path)
        XCTAssertEqual(try Data(contentsOf: location.resolve("Audio/live/microphone.wav")), Data("audio".utf8))
    }

    func testNestedDestinationIsRefusedBeforeCreatingFiles() throws {
        let workspace = try temporaryDirectory()
        defer { try? manager.removeItem(at: workspace) }
        _ = try recording("A", under: workspace)
        let destination = workspace.appendingPathComponent("Audio/nested")
        let location = RecordingsLocation(defaultRoot: workspace, markerURL: workspace.appendingPathComponent("root.txt"))
        XCTAssertThrowsError(try location.migrateRoot(to: destination))
        XCTAssertFalse(manager.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: location.resolve("Audio/A/microphone.wav")), Data("audio".utf8))
    }

    func testPartialSourceRemovalFailureRestoresCompleteOriginal() throws {
        let workspace = try temporaryDirectory()
        defer { try? manager.removeItem(at: workspace) }
        let origin = workspace.appendingPathComponent("origin")
        let destination = workspace.appendingPathComponent("destination")
        let source = try recording("A", under: origin)
        try Data("system channel".utf8).write(to: source.appendingPathComponent("system.wav"))
        let location = RecordingsLocation(defaultRoot: origin, markerURL: origin.appendingPathComponent("root.txt"))
        var committed = false
        XCTAssertThrowsError(try location.performMigration(
            from: origin, to: destination,
            commitRoot: { committed = true },
            removeSource: { entry in
                try self.manager.removeItem(at: entry.appendingPathComponent("microphone.wav"))
                throw MarkerFailure.failed
            }))
        XCTAssertFalse(committed)
        XCTAssertEqual(try Data(contentsOf: location.resolve("Audio/A/microphone.wav")), Data("audio".utf8))
        XCTAssertEqual(try Data(contentsOf: location.resolve("Audio/A/system.wav")), Data("system channel".utf8))
        XCTAssertFalse(manager.fileExists(atPath: destination.appendingPathComponent("Audio/A").path))
        let recovery = try manager.contentsOfDirectory(at: origin.appendingPathComponent("Audio"),
                                                      includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".superseded-A-") }
        XCTAssertEqual(recovery.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(recovery.first).appendingPathComponent("system.wav")),
                       Data("system channel".utf8))
    }

    func testRollbackPreservesAnOriginRecreatedByAnotherWriter() throws {
        let workspace = try temporaryDirectory()
        defer { try? manager.removeItem(at: workspace) }
        let origin = workspace.appendingPathComponent("origin")
        let destination = workspace.appendingPathComponent("destination")
        let source = try recording("A", under: origin)
        let location = RecordingsLocation(defaultRoot: origin, markerURL: origin.appendingPathComponent("root.txt"))
        XCTAssertThrowsError(try location.performMigration(from: origin, to: destination, commitRoot: {
            try self.manager.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("new writer".utf8).write(to: source.appendingPathComponent("new.wav"))
            throw MarkerFailure.failed
        }))
        XCTAssertEqual(try Data(contentsOf: location.resolve("Audio/A/microphone.wav")), Data("audio".utf8))
        let recovery = try manager.contentsOfDirectory(at: origin.appendingPathComponent("Audio"),
                                                      includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".superseded-A-") }
        XCTAssertEqual(recovery.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(recovery.first).appendingPathComponent("new.wav")),
                       Data("new writer".utf8))
    }

    func testResetWithoutMarkerIsIdempotent() throws {
        let workspace = try temporaryDirectory()
        defer { try? manager.removeItem(at: workspace) }
        let location = RecordingsLocation(defaultRoot: workspace, markerURL: workspace.appendingPathComponent("root.txt"))
        XCTAssertNoThrow(try location.setRoot(nil))
        XCTAssertNoThrow(try location.setRoot(nil))
    }

    private func temporaryDirectory() throws -> URL {
        let url = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func recording(_ name: String, under root: URL) throws -> URL {
        let directory = root.appendingPathComponent("Audio/\(name)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: directory.appendingPathComponent("microphone.wav"))
        return directory
    }

    private enum MarkerFailure: Error { case failed }
}
