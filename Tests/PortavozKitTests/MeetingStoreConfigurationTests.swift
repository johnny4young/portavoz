import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit
@testable import PortavozTestSupport

final class MeetingStoreConfigurationTests: XCTestCase {
    func testFileStoreUsesWALModeBusyTimeoutAndZeroMemoryMap() async throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try MeetingStore(
            databaseURL: workspace.appendingPathComponent("portavoz.sqlite"))

        let writerBusy = try await store.database.write { database in
            try Int.fetchOne(database, sql: "PRAGMA busy_timeout")
        }
        let settings = try await store.database.read { database -> (journal: String?, busy: Int?, mmap: Int64?) in
            let journal = try String.fetchOne(database, sql: "PRAGMA journal_mode")
            let busy = try Int.fetchOne(database, sql: "PRAGMA busy_timeout")
            let mmap = try Int64.fetchOne(database, sql: "PRAGMA main.mmap_size")
            return (journal?.lowercased(), busy, mmap)
        }

        XCTAssertEqual(settings.journal, "wal")
        XCTAssertEqual(writerBusy, Int(MeetingStore.defaultBusyTimeout * 1_000))
        XCTAssertEqual(settings.busy, Int(MeetingStore.defaultBusyTimeout * 1_000))
        XCTAssertEqual(settings.mmap, 0)
        try store.database.close()
    }

    func testWALAllowsConcurrentExternalReaderAndInvalidatesSemanticCacheAcrossExternalWrite() async throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let databaseURL = workspace.appendingPathComponent("portavoz.sqlite")
        let store = try await MeetingStore.open(databaseURL: databaseURL)

        let meeting = Meeting(title: "WAL concurrency", startedAt: Date())
        let firstSegment = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "Initial roadmap item.",
            startTime: 0,
            endTime: 1,
            isFinal: true)
        try await store.save(meeting)
        try await store.save([firstSegment])
        let firstCandidates = try await store.segmentsNeedingEmbeddings()
        _ = try await store.storeEmbeddings([firstSegment.id: [1, 0]], for: firstCandidates)

        // Hold an external read transaction open while writing through MeetingStore.
        var readerConfig = Configuration()
        readerConfig.readonly = true
        readerConfig.allowsUnsafeTransactions = true
        let externalReader = try DatabaseQueue(path: databaseURL.path, configuration: readerConfig)
        try await externalReader.unsafeRead { db in
            try db.execute(sql: "BEGIN")
            _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM segment")
        }
        let secondSegment = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "Written while an external reader held a snapshot.",
            startTime: 2,
            endTime: 3,
            isFinal: true)
        try await store.save([secondSegment])
        let secondCandidates = try await store.segmentsNeedingEmbeddings()
        _ = try await store.storeEmbeddings([secondSegment.id: [0, 1]], for: secondCandidates)
        try await externalReader.unsafeRead { try $0.execute(sql: "ROLLBACK") }
        try externalReader.close()

        // Warm the packed Float16 cache, then mutate via a separate writer connection
        // (simulating portavoz-cli / MCP) and verify the cache invalidates automatically.
        let warmHits = try await store.searchSemantic([0, 1], limit: 2)
        XCTAssertEqual(warmHits.first?.segmentID, secondSegment.id)

        let externalStore = try MeetingStore(databaseURL: databaseURL)
        let thirdSegment = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "Added by an external CLI writer.",
            startTime: 4,
            endTime: 5,
            isFinal: true)
        try await externalStore.save([thirdSegment])
        let thirdCandidates = try await externalStore.segmentsNeedingEmbeddings()
        _ = try await externalStore.storeEmbeddings([thirdSegment.id: [0.6, 0.8]], for: thirdCandidates)
        try externalStore.database.close()

        let refreshedHits = try await store.searchSemantic([0.6, 0.8], limit: 3)
        XCTAssertEqual(refreshedHits.first?.segmentID, thirdSegment.id)
        store.releaseSemanticSearchCache()
        let postEvictionHits = try await store.searchSemantic([0.6, 0.8], limit: 3)
        XCTAssertEqual(postEvictionHits.map(\.segmentID), refreshedHits.map(\.segmentID))
        XCTAssertEqual(postEvictionHits.map(\.semanticSimilarity), refreshedHits.map(\.semanticSimilarity))
        try store.database.close()
    }

    func testMappedFileStorePreservesSemanticRankingAcrossReopen() async throws {
        let workspace = try temporaryWorkspace()
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

    private func temporaryWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortavozWALStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        return workspace
    }
}
