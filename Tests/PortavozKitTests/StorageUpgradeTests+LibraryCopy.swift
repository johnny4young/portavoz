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
        // A live library keeps committed pages in its -wal file, which a plain copy would drop.
        let wal = (try? FileManager.default.attributesOfItem(atPath: path + "-wal")[.size] as? Int) ?? 0
        XCTAssertEqual(wal, 0, "Point PORTAVOZ_LIBRARY_COPY at a backup, not a live library.")
        guard wal == 0 else { return }
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

        // Expiring every legacy row keeps every note.
        let reopened = try XCTUnwrap(store)
        let expired = try await expireEveryLegacyRow(in: reopened)
        XCTAssertTrue(expired)
        try await assertLibrary(in: reopened, matches: before.afterLegacyExpiry)
    }

    private struct LibraryCounts: Equatable {
        var meetings: Int
        var notes: Int
        var segments: Int
        var summaries: Int
        var actionItems: Int
        var enhancedNotes: Int
        var translations: Int
        var egress: Int
        var noteLinks: Int

        var afterLegacyExpiry: Self {
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
            summaries = try count("SELECT COUNT(*) FROM summary")
            actionItems = try count("SELECT COUNT(*) FROM actionItem")
            enhancedNotes = try count("SELECT COUNT(*) FROM enhancedNote")
            translations = try count("SELECT COUNT(*) FROM transcriptTranslation")
            egress = try count("SELECT COUNT(*) FROM globalDataEgressEvent")
            noteLinks = try count(StorageUpgradeTests.legacyNoteLinkCount)
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
