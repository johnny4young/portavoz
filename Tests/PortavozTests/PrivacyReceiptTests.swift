import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class PrivacyReceiptTests: XCTestCase {
    func testV6LibraryMigratesWithHonestPartialCoverage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-privacy-migration-\(UUID().uuidString)")
        let databaseURL = root.appendingPathComponent("portavoz.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let legacyDatabase = try DatabaseQueue(path: databaseURL.path)
        try StorageSchema.migrator().migrate(legacyDatabase, upTo: "v6")
        let meetingID = MeetingID()
        let legacyDate = Date(timeIntervalSince1970: 1_700_000_000)
        try await legacyDatabase.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meeting (
                        id, title, startedAt, retention, visibility,
                        createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    meetingID.rawValue.uuidString, "Legacy meeting", legacyDate,
                    try MeetingRecord.encode(.keep), "private", legacyDate, legacyDate,
                ])
        }

        let beforeMigration = Date()
        let store = try MeetingStore(databaseURL: databaseURL)
        let afterMigration = Date()
        let storedReceipt = try await store.privacyReceipt(for: meetingID)
        let receipt = try XCTUnwrap(storedReceipt)

        guard case .since(let trackingStartedAt) = receipt.coverage else {
            return XCTFail("a migrated meeting must not claim lifetime coverage")
        }
        // GRDB's SQLite datetime round-trip is millisecond-precise. Compare
        // against the wall-clock bracket at that same durable precision.
        XCTAssertGreaterThanOrEqual(
            trackingStartedAt,
            beforeMigration.addingTimeInterval(-0.001))
        XCTAssertLessThanOrEqual(
            trackingStartedAt,
            afterMigration.addingTimeInterval(0.001))
        XCTAssertEqual(receipt.status, .noRemoteTransferRecorded)

        try await store.database.read { db in
            XCTAssertEqual(StorageSchema.version, 7)
            XCTAssertEqual(
                try String.fetchAll(
                    db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"),
                ["v1", "v2", "v3", "v4", "v5", "v6", "v7"])
            XCTAssertEqual(
                try Set(db.columns(in: "dataEgressEvent").map(\.name)),
                [
                    "id", "meetingID", "operation", "destinationScope",
                    "destinationHost", "dataClassification", "consentSource",
                    "providerID", "modelID", "attemptedAt",
                ])
            XCTAssertEqual(
                try Set(db.columns(in: "privacyReceiptCoverage").map(\.name)),
                ["id", "trackingStartedAt"])
            let foreignKeys = try Row.fetchAll(
                db, sql: "PRAGMA foreign_key_list(dataEgressEvent)")
            XCTAssertEqual(Set(foreignKeys.map { $0["table"] as String }), ["meeting"])
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testReceiptRoundTripsContentFreeLocalAndRemoteEvidence() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Planning", startedAt: Date())
        try await store.save(meeting)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let local = event(
            meetingID: meeting.id,
            scope: .localDevice,
            host: "localhost",
            attemptedAt: base)
        let remote = event(
            meetingID: meeting.id,
            operation: .publishGitHubGist,
            scope: .remote,
            host: "api.github.com",
            classification: .meetingExportDocument,
            consent: .explicitGistPublish,
            modelID: nil,
            attemptedAt: base.addingTimeInterval(1))
        try await store.recordDataEgressEvent(local)
        try await store.recordDataEgressEvent(remote)
        try await store.saveGenerationRun(GenerationRun(
            meetingID: meeting.id,
            kind: .summary,
            providerID: "foundation-models",
            modelID: "system-language-model",
            inputFingerprint: "sha256:fixture",
            configJSON: #"{"recipe":"general"}"#,
            outputLanguage: "en",
            startedAt: base,
            finishedAt: base.addingTimeInterval(2),
            outcome: .failed,
            metricsJSON: #"{"outputUTF8Bytes":0}"#))

        let storedReceipt = try await store.privacyReceipt(for: meeting.id)
        let receipt = try XCTUnwrap(storedReceipt)
        XCTAssertEqual(receipt.coverage, .complete)
        XCTAssertEqual(receipt.status, .remoteTransferAttempted)
        XCTAssertEqual(receipt.localDeviceEvents, [local])
        XCTAssertEqual(receipt.remoteEvents, [remote])
        XCTAssertEqual(receipt.generation.count, 1)
        XCTAssertEqual(receipt.generation.first?.providerID, "foundation-models")

        let persistedColumns = try await store.database.read { db in
            try Set(db.columns(in: "dataEgressEvent").map(\.name))
        }
        for forbidden in [
            "payload", "body", "url", "path", "transcript", "prompt",
            "summary", "notes", "actionItem", "content",
        ] {
            XCTAssertFalse(persistedColumns.contains(forbidden), forbidden)
        }
    }

    func testReceiptWriterRejectsUnattributedUnknownOrForgedEvidence() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Planning", startedAt: Date())
        try await store.save(meeting)

        do {
            try await store.recordDataEgressEvent(event(
                meetingID: nil,
                scope: .remote,
                host: "api.example.com"))
            XCTFail("missing meeting identity must fail")
        } catch {
            guard case StorageError.invalidDataEgressEvent = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        do {
            try await store.recordDataEgressEvent(event(
                meetingID: MeetingID(),
                scope: .remote,
                host: "api.example.com"))
            XCTFail("unknown meeting must fail")
        } catch {
            guard case StorageError.meetingNotFound = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let forged = DataEgressEvent(
            meetingID: meeting.id,
            operation: .summaryGeneration,
            destinationScope: .remote,
            destinationHost: "api.example.com",
            dataClassification: .meetingSummaryMaterial,
            consentSource: .summaryEngineSettings,
            providerID: "other.example.com",
            modelID: "summary-model",
            attemptedAt: Date())
        do {
            try await store.recordDataEgressEvent(forged)
            XCTFail("forged provider identity must fail")
        } catch {
            guard case StorageError.invalidDataEgressEvent = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let falseLocal = event(
            meetingID: meeting.id,
            scope: .localDevice,
            host: "api.example.com")
        do {
            try await store.recordDataEgressEvent(falseLocal)
            XCTFail("a remote host must not be persisted as local")
        } catch {
            guard case StorageError.invalidDataEgressEvent = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let events = try await store.dataEgressEvents(for: meeting.id)
        XCTAssertTrue(events.isEmpty)
    }

    private func event(
        meetingID: MeetingID?,
        operation: DataEgressOperation = .summaryGeneration,
        scope: DataEgressDestinationScope,
        host: String,
        classification: DataEgressClassification = .meetingSummaryMaterial,
        consent: DataEgressConsentSource = .summaryEngineSettings,
        modelID: String? = "summary-model",
        attemptedAt: Date = Date()
    ) -> DataEgressEvent {
        DataEgressEvent(
            meetingID: meetingID,
            operation: operation,
            destinationScope: scope,
            destinationHost: host,
            dataClassification: classification,
            consentSource: consent,
            providerID: host,
            modelID: modelID,
            attemptedAt: attemptedAt)
    }
}
