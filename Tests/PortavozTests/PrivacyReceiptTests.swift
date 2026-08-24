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
            XCTAssertEqual(StorageSchema.version, 44)
            XCTAssertEqual(
                try String.fetchAll(
                    db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"),
                [
                    "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8",
                    "v9", "v10", "v11", "v12", "v13", "v14", "v15", "v16", "v17", "v18",
                    "v19", "v20", "v21", "v22", "v23", "v24", "v25", "v26", "v27", "v28",
                    "v29", "v30", "v31", "v32", "v33", "v34", "v35", "v36", "v37", "v38", "v39", "v40",
                    "v41", "v42", "v43", "v44",
                ])
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
        XCTAssertEqual(receipt.syncDisclosure, .noCloudCopyRecorded)
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

    func testGlobalAskReceiptRoundTripsWithoutFalseMeetingAttribution() async throws {
        let store = try MeetingStore.inMemory()
        let attemptedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let event = DataEgressEvent(
            meetingID: nil,
            operation: .askAnswerGeneration,
            destinationScope: .localDevice,
            destinationHost: "localhost",
            dataClassification: .meetingAnswerMaterial,
            consentSource: .summaryEngineSettings,
            providerID: "localhost",
            modelID: "qwen-local",
            attemptedAt: attemptedAt)

        try await store.recordDataEgressEvent(event)

        let events = try await store.globalDataEgressEvents()
        XCTAssertEqual(events, [event])
        let columns = try await store.database.read { database in
            try Set(database.columns(in: "globalDataEgressEvent").map(\.name))
        }
        XCTAssertFalse(columns.contains("meetingID"))
        for forbidden in [
            "payload", "body", "url", "path", "transcript", "prompt",
            "summary", "notes", "content",
        ] {
            XCTAssertFalse(columns.contains(forbidden), forbidden)
        }
    }

    func testGlobalWebReceiptRoundTripsWithoutURLOrMeetingContent() async throws {
        let store = try MeetingStore.inMemory()
        let attemptedAt = Date(timeIntervalSince1970: 1_787_529_600)
        let event = globalWebEvent(
            scope: .remote,
            host: "www.example.com",
            attemptedAt: attemptedAt)

        try await store.recordDataEgressEvent(event)

        let events = try await store.globalDataEgressEvents()
        XCTAssertEqual(events, [event])
        let record = try await store.database.read { database in
            try XCTUnwrap(GlobalDataEgressEventRecord.fetchOne(database))
        }
        XCTAssertEqual(record.destinationHost, "www.example.com")
        XCTAssertNil(record.modelID)
        XCTAssertEqual(record.attemptedAt, attemptedAt)
        let encoded = String(data: try JSONEncoder().encode(event), encoding: .utf8)!
        for forbidden in [
            "https://", "/source", "?query", "question", "transcript",
        ] {
            XCTAssertFalse(encoded.contains(forbidden), forbidden)
        }
    }

    func testGlobalWebAnswerReceiptUsesPublicMaterialClassification() async throws {
        let store = try MeetingStore.inMemory()
        let event = globalAskEvent(
            classification: .publicWebAnswerMaterial,
            attemptedAt: Date(timeIntervalSince1970: 1_787_529_600))

        try await store.recordDataEgressEvent(event)

        let persisted = try await store.globalDataEgressEvents()
        XCTAssertEqual(persisted, [event])
        XCTAssertEqual(
            persisted.first?.dataClassification,
            .publicWebAnswerMaterial)
    }

    func testV43GlobalAskReceiptSurvivesV44WebSchemaMigration() async throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v43")
        let id = DataEgressEventID().rawValue.uuidString
        let attemptedAt = Date(timeIntervalSince1970: 1_787_529_600)
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO globalDataEgressEvent (
                        id, operation, destinationScope, destinationHost,
                        dataClassification, consentSource, providerID,
                        modelID, attemptedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    id, "ask-answer-generation", "local-device", "localhost",
                    "meeting-answer-material", "summary-engine-settings",
                    "localhost", "qwen-local", attemptedAt,
                ])
        }

        try migrator.migrate(database)

        try await database.read { db in
            let row = try XCTUnwrap(
                GlobalDataEgressEventRecord.fetchOne(db, key: id))
            XCTAssertEqual(row.operation, "ask-answer-generation")
            XCTAssertEqual(row.modelID, "qwen-local")
            XCTAssertEqual(row.attemptedAt, attemptedAt)
            XCTAssertEqual(
                Array(try String.fetchAll(
                    db,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
                ).suffix(2)),
                ["v43", "v44"])
        }
    }

    func testGlobalReceiptRejectsMetadataOutsideLocalAskContract() async throws {
        let store = try MeetingStore.inMemory()
        let invalid: [DataEgressEvent] = [
            globalAskEvent(operation: .summaryGeneration),
            globalAskEvent(classification: .meetingSummaryMaterial),
            globalAskEvent(consent: .explicitSummaryProvider),
            globalAskEvent(modelID: " "),
        ]

        for event in invalid {
            do {
                try await store.recordDataEgressEvent(event)
                XCTFail("out-of-contract global receipt must fail: \(event)")
            } catch {
                guard case StorageError.invalidDataEgressEvent = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
        let persisted = try await store.globalDataEgressEvents()
        XCTAssertTrue(persisted.isEmpty)
    }

    func testGlobalReceiptRejectsForgedWebMetadata() async throws {
        let store = try MeetingStore.inMemory()
        let invalid = [
            globalWebEvent(classification: .meetingAnswerMaterial),
            globalWebEvent(consent: .summaryEngineSettings),
            globalWebEvent(modelID: "model-must-be-nil"),
            globalWebEvent(operation: .summaryGeneration),
        ]

        for event in invalid {
            do {
                try await store.recordDataEgressEvent(event)
                XCTFail("forged Web receipt must fail: \(event)")
            } catch {
                guard case StorageError.invalidDataEgressEvent = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
        let persisted = try await store.globalDataEgressEvents()
        XCTAssertTrue(persisted.isEmpty)
    }

    func testGlobalReceiptReadFailsClosedOnCorruptIdentity() async throws {
        let store = try MeetingStore.inMemory()
        try await store.recordDataEgressEvent(globalWebEvent(
            scope: .remote,
            host: "www.example.com"))
        try await store.database.write { database in
            try database.execute(
                sql: "UPDATE globalDataEgressEvent SET providerID = ?",
                arguments: ["forged.example.net"])
        }

        do {
            _ = try await store.globalDataEgressEvents()
            XCTFail("corrupt receipt identity must fail closed")
        } catch {
            guard case StorageError.invalidDataEgressEvent = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testReceiptWriterRejectsNonFiniteAttemptTime() async throws {
        let store = try MeetingStore.inMemory()
        let invalid = globalWebEvent(
            attemptedAt: Date(timeIntervalSinceReferenceDate: .nan))

        do {
            try await store.recordDataEgressEvent(invalid)
            XCTFail("non-finite receipt time must fail")
        } catch {
            guard case StorageError.invalidDataEgressEvent = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testReceiptDisclosesAnAcknowledgedPrivateCloudCopyForever() async throws {
        let store = try MeetingStore.inMemory()
        var meeting = Meeting(title: "Planning", startedAt: Date())
        try await store.save(meeting)

        // The journal queues every save unconditionally, so an unacknowledged
        // entry proves nothing about the cloud and must not change the receipt.
        var receipt = try await store.privacyReceipt(for: meeting.id)
        XCTAssertEqual(receipt?.syncDisclosure, .noCloudCopyRecorded)

        let pending = try await store.pendingMeetingSyncChanges()
        let change = try XCTUnwrap(pending.first { $0.meetingID == meeting.id })
        try await store.acknowledgeMeetingSync(change)
        receipt = try await store.privacyReceipt(for: meeting.id)
        XCTAssertEqual(receipt?.syncDisclosure, .acknowledgedByPrivateCloud)

        // A later local edit re-queues the meeting, but the acknowledged copy
        // already exists — the disclosure must never revert.
        meeting.title = "Planning renamed after upload"
        try await store.save(meeting)
        receipt = try await store.privacyReceipt(for: meeting.id)
        XCTAssertEqual(receipt?.syncDisclosure, .acknowledgedByPrivateCloud)
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

    private func globalAskEvent(
        operation: DataEgressOperation = .askAnswerGeneration,
        classification: DataEgressClassification = .meetingAnswerMaterial,
        consent: DataEgressConsentSource = .summaryEngineSettings,
        modelID: String = "qwen-local",
        attemptedAt: Date = Date()
    ) -> DataEgressEvent {
        DataEgressEvent(
            meetingID: nil,
            operation: operation,
            destinationScope: .localDevice,
            destinationHost: "localhost",
            dataClassification: classification,
            consentSource: consent,
            providerID: "localhost",
            modelID: modelID,
            attemptedAt: attemptedAt)
    }

    private func globalWebEvent(
        operation: DataEgressOperation = .webSourceRetrieval,
        scope: DataEgressDestinationScope = .localDevice,
        host: String = "127.0.0.1",
        classification: DataEgressClassification = .publicWebSourceRequest,
        consent: DataEgressConsentSource = .explicitWebAsk,
        modelID: String? = nil,
        attemptedAt: Date = Date()
    ) -> DataEgressEvent {
        DataEgressEvent(
            meetingID: nil,
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
