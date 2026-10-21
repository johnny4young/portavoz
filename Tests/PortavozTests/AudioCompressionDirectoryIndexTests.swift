import Foundation
import GRDB
import PortavozCore
import Testing

@testable import StorageKit

struct AudioCompressionDirectoryIndexTests {
    @Test func upgradeIndexesTheActualOwnerQueryWithoutRejectingDuplicateDirectories() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v52")
        let directory = "Audio/\(UUID().uuidString)"
        let timestamp = Date(timeIntervalSince1970: 1_783_695_600)
        try database.write { db in
            for title in ["Original owner", "Aliased owner"] {
                try MeetingRecord(
                    Meeting(title: title, startedAt: timestamp, audioDirectory: directory),
                    createdAt: timestamp, updatedAt: timestamp).insert(db)
            }
        }
        let before = try database.read { try ownerQueryPlan(in: $0, directory: directory) }
        #expect(before.contains { $0.contains("SCAN meeting") })

        try migrator.migrate(database, upTo: "v53")

        try database.read { db in
            #expect(try String.fetchOne(
                db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1") == "v53")
            let indexes = try Row.fetchAll(db, sql: "PRAGMA index_list('meeting')")
            let index = try #require(indexes.first { ($0["name"] as String) == "meeting_on_audioDirectory" })
            #expect((index["unique"] as Int) == 0)
            #expect(try MeetingStore.audioCompressionDirectoryOwners(directory).fetchAll(db).count == 2)
            let plan = try ownerQueryPlan(in: db, directory: directory)
            #expect(plan.contains { $0.contains("SEARCH meeting USING INDEX meeting_on_audioDirectory") })
            #expect(plan.contains { $0.contains("SCAN meeting") } == false)
        }
    }

    private func ownerQueryPlan(in database: Database, directory: String) throws -> [String] {
        let statement = try MeetingStore.audioCompressionDirectoryOwners(directory)
            .makePreparedRequest(database).statement
        return try Row.fetchAll(
            database, sql: "EXPLAIN QUERY PLAN \(statement.sql)",
            arguments: statement.arguments).map { $0["detail"] as String }
    }
}
