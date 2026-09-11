import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class MeetingStoreConfigurationTests: XCTestCase {
    func testMemoryMapVolumeClassificationResolvesDatabaseSymlinks() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortavozMappedStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let targetDirectory = workspace.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(
            at: targetDirectory,
            withIntermediateDirectories: true)
        let targetDatabase = targetDirectory.appendingPathComponent("portavoz.sqlite")
        try Data().write(to: targetDatabase)
        let linkedDatabase = workspace.appendingPathComponent("linked.sqlite")
        try FileManager.default.createSymbolicLink(
            at: linkedDatabase,
            withDestinationURL: targetDatabase)

        XCTAssertEqual(
            MeetingStore.memoryMappedDatabaseDirectory(for: linkedDatabase),
            targetDirectory.standardizedFileURL.resolvingSymlinksInPath())
    }

    func testInternalFileStoreAppliesBoundedSQLiteMemoryMap() async throws {
        let workspace = try internalTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try MeetingStore(
            databaseURL: workspace.appendingPathComponent("portavoz.sqlite"))

        let configuredBytes = try await store.database.read { database in
            try Int64.fetchOne(database, sql: "PRAGMA main.mmap_size")
        }

        XCTAssertEqual(
            configuredBytes,
            MeetingStore.maximumMemoryMappedDatabaseBytes)
        try store.database.close()
    }

    func testMappedFileStorePreservesSemanticRankingAcrossReopen() async throws {
        let workspace = try internalTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let databaseURL = workspace.appendingPathComponent("portavoz.sqlite")
        let meeting = Meeting(title: "Mapped semantic store", startedAt: Date())
        let segments = [
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "The release plan stays on Friday.",
                startTime: 0,
                endTime: 1,
                isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "The archive remains available.",
                startTime: 2,
                endTime: 3,
                isFinal: true)
        ]

        let firstStore = try MeetingStore(databaseURL: databaseURL)
        try await firstStore.save(meeting)
        try await firstStore.save(segments)
        let candidates = try await firstStore.segmentsNeedingEmbeddings()
        _ = try await firstStore.storeEmbeddings(
            [
                segments[0].id: [1, 0],
                segments[1].id: [0, 1]
            ],
            for: candidates)
        let firstRanking = try await firstStore.searchSemantic([1, 0], limit: 2)
        try firstStore.database.close()

        let reopenedStore = try MeetingStore(databaseURL: databaseURL)
        let reopenedRanking = try await reopenedStore.searchSemantic([1, 0], limit: 2)

        XCTAssertEqual(firstRanking.map(\.segmentID), segments.map(\.id))
        XCTAssertEqual(reopenedRanking.map(\.segmentID), firstRanking.map(\.segmentID))
        XCTAssertEqual(
            reopenedRanking.map(\.semanticSimilarity),
            firstRanking.map(\.semanticSimilarity))
        try reopenedStore.database.close()
    }

    private func internalTemporaryWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortavozMappedStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        let volume = try workspace.resourceValues(
            forKeys: [.volumeIsLocalKey, .volumeIsInternalKey])
        try XCTSkipUnless(
            volume.volumeIsLocal == true && volume.volumeIsInternal == true,
            "the mapped-store contract applies only to internal local volumes")
        return workspace
    }
}
