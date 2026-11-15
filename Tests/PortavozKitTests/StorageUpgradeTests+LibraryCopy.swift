import Foundation
import GRDB
import XCTest

@testable import StorageKit

// A coherent backup of a real library, restored into a fresh folder and opened with today's
// code. It runs only when PORTAVOZ_LIBRARY_COPY names that backup, and never writes to it.
extension StorageUpgradeTests {
    func testARestoredLibraryBackupOpensWithEverythingIntact() async throws {
        guard let path = ProcessInfo.processInfo.environment["PORTAVOZ_LIBRARY_COPY"] else {
            throw XCTSkip("Set PORTAVOZ_LIBRARY_COPY to a SQLite backup of a library.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-library-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("portavoz.sqlite")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
        let before = try LibraryCounts(at: url)
        XCTAssertGreaterThan(before.meetings, 0, "The backup holds no meeting.")

        var store: MeetingStore? = try MeetingStore(databaseURL: url)
        try await assertLibrary(in: XCTUnwrap(store), matches: before)
        store = nil
        store = try MeetingStore(databaseURL: url)
        try await assertLibrary(in: XCTUnwrap(store), matches: before)

        // A clock past every horizon expires each legacy dictation row and keeps every note.
        let reopened = try XCTUnwrap(store)
        try await reopened.purgeExpiredLegacyDictationData(now: Date().addingTimeInterval(400 * 86_400))
        let remaining = try await reopened.legacyDictationRows()
        XCTAssertTrue(remaining.isEmpty)
        try await assertLibrary(in: reopened, matches: before.afterLegacyDictationExpiry)
    }

    private struct LibraryCounts: Equatable {
        var meetings: Int
        var notes: Int
        var segments: Int
        var egress: Int
        var noteLinks: Int

        var afterLegacyDictationExpiry: Self {
            var counts = self
            counts.noteLinks = 0
            return counts
        }

        init(at url: URL) throws {
            let database = try DatabaseQueue(path: url.path)
            self = try database.read { try Self(database: $0) }
        }

        init(database: Database) throws {
            let count = { (sql: String) in try Int.fetchOne(database, sql: sql) ?? 0 }
            meetings = try count("SELECT COUNT(*) FROM meeting")
            notes = try count("SELECT COUNT(*) FROM contextItem WHERE kind = 'note'")
            segments = try count("SELECT COUNT(*) FROM segment")
            egress = try count("SELECT COUNT(*) FROM globalDataEgressEvent")
            noteLinks = try count("SELECT COUNT(*) FROM dictationMeetingNote")
        }
    }

    private func assertLibrary(in store: MeetingStore, matches expected: LibraryCounts) async throws {
        // An FTS5 integrity check is issued as a write, though it changes nothing.
        try await store.database.write { database in
            XCTAssertEqual(try LibraryCounts(database: database), expected)
            XCTAssertEqual(try String.fetchAll(database, sql: "PRAGMA integrity_check"), ["ok"])
            XCTAssertTrue(try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty)
            try Self.assertSearchIndexesHealthy(in: database)
        }
        let journal = try await store.globalDataEgressEvents()
        XCTAssertEqual(journal.count, expected.egress)
    }
}
