import Foundation
import GRDB
@testable import IntegrationsKit
@testable import IntelligenceKit
import PortavozCore
@testable import StorageKit
import XCTest

/// A 1.x library keeps its dictation polish receipts; nothing can send or record a new one.
final class LegacyDictationEgressTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testGatewayRefusesDictationPolishOnEveryDestination() throws {
        for host in ["http://localhost:11434/v1", "http://127.0.0.1:11434/v1", "https://api.example.com/v1"] {
            let (request, metadata) = try polishRequest(endpoint: try XCTUnwrap(URL(string: host)))
            XCTAssertThrowsError(try URLSessionDataEgressGateway.validate(request, metadata: metadata)) { error in
                XCTAssertEqual(
                    error as? DataEgressGatewayError, .invalidMetadata("Dictation polish is retired"), host)
            }
        }
    }

    func testStoreRefusesNewPolishReceipts() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Weekly", startedAt: now)
        try await store.save(meeting)
        for event in [polishEvent(), polishEvent(meetingID: meeting.id)] {
            do {
                try await store.recordDataEgressEvent(event)
                XCTFail("a new polish receipt must fail: \(event)")
            } catch StorageError.invalidDataEgressEvent(let reason) {
                XCTAssertEqual(reason, "dictation polish is retired")
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        let global = try await store.globalDataEgressEvents()
        let owned = try await store.dataEgressEvents(for: meeting.id)
        XCTAssertTrue(global.isEmpty)
        XCTAssertTrue(owned.isEmpty)
    }

    func testGlobalJournalStillReadsAContentFreePolishReceipt() async throws {
        let store = try MeetingStore.inMemory()
        let event = polishEvent()
        try await store.database.write { db in
            try GlobalDataEgressEventRecord(event, modelID: event.modelID).insert(db)
        }

        let events = try await store.globalDataEgressEvents()

        XCTAssertEqual(events, [event])
        XCTAssertNil(events.first?.meetingID)
    }

    func testV59AdmitsPolishInHistoryAndJournalWithoutLosingSearchOrMeetingLinks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-polish-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = self.now
        let dictationID = UUID()
        let meeting = Meeting(title: "Weekly", startedAt: now, endedAt: now.addingTimeInterval(1_800))
        let note = ContextItem(meetingID: meeting.id, kind: .note, content: "Revisar el presupuesto.", timestamp: 60)
        let askReceipt = DataEgressEvent(
            meetingID: nil, operation: .askAnswerGeneration, destinationScope: .localDevice,
            destinationHost: "localhost", dataClassification: .meetingAnswerMaterial,
            consentSource: .summaryEngineSettings, providerID: "localhost", modelID: "qwen-local",
            attemptedAt: now)
        let legacy = try DatabaseQueue(path: url.path)
        try StorageSchema.migrator().migrate(legacy, upTo: "v58")
        try await legacy.write { db in
            try MeetingRecord(meeting, createdAt: now, updatedAt: now).insert(db)
            try Self.insertDictation(id: dictationID, mode: "clean", text: "Revisar el presupuesto.", at: now, in: db)
            try ContextItemRecord(note, createdAt: now, updatedAt: now).insert(db)
            try db.execute(
                sql: "INSERT INTO dictationMeetingNote (dictationID, meetingID, contextItemID, createdAt) VALUES (?, ?, ?, ?)",
                arguments: [dictationID.uuidString, meeting.id.rawValue.uuidString, note.id.uuidString, now])
            try GlobalDataEgressEventRecord(askReceipt, modelID: "qwen-local").insert(db)
            XCTAssertThrowsError(try Self.insertDictation(id: UUID(), mode: "polish", at: now, in: db))
        }
        try legacy.close()

        let store = try MeetingStore(databaseURL: url)
        let (found, links) = try await store.database.read { db in
            let found = try String.fetchAll(db, sql: """
                SELECT dictationRecord.id FROM dictationRecordSearch
                JOIN dictationRecord ON dictationRecord.rowid = dictationRecordSearch.rowid
                WHERE dictationRecordSearch MATCH '"presupuesto"'
                """)
            let links = try String.fetchAll(db, sql: """
                SELECT meeting.title FROM dictationMeetingNote AS link
                JOIN meeting ON meeting.id = link.meetingID WHERE link.dictationID = ?
                """, arguments: [dictationID.uuidString])
            return (found, links)
        }
        let polish = polishEvent()
        try await store.database.write { db in
            try GlobalDataEgressEventRecord(polish, modelID: polish.modelID).insert(db)
        }
        let journal = try await store.globalDataEgressEvents()

        XCTAssertEqual(found, [dictationID.uuidString])
        XCTAssertEqual(links, ["Weekly"])
        XCTAssertEqual(journal.map(\.operation), [.askAnswerGeneration, .dictationPolish])
        try await store.database.write { db in
            XCTAssertNoThrow(try Self.insertDictation(id: UUID(), mode: "polish", at: now, in: db))
            XCTAssertThrowsError(try Self.insertDictation(id: UUID(), mode: "fancy", at: now, in: db))
            XCTAssertThrowsError(try db.execute(sql: """
                INSERT INTO globalDataEgressEvent (
                    id, operation, destinationScope, destinationHost, dataClassification,
                    consentSource, providerID, modelID, attemptedAt)
                VALUES (?, 'dictation-polish', 'remote', 'api.example.com', 'dictation-text',
                    'dictation-polish-mode', 'api.example.com', 'm', ?)
                """, arguments: [UUID().uuidString, now]))
            XCTAssertThrowsError(try db.execute(sql: """
                INSERT INTO globalDataEgressEvent (
                    id, operation, destinationScope, destinationHost, dataClassification,
                    consentSource, providerID, modelID, attemptedAt)
                VALUES (?, 'dictation-rewrite', 'local-device', 'localhost', 'dictation-text',
                    'dictation-polish-mode', 'localhost', 'm', ?)
                """, arguments: [UUID().uuidString, now]))
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    private func polishRequest(endpoint: URL) throws -> (URLRequest, DataEgressRequest) {
        let request = try OpenAICompatibleChatCodec.urlRequest(
            endpoint: endpoint, model: "qwen-local", apiKey: "ollama",
            system: "Clean up the text.", user: "hola", temperature: 0, maxTokens: 64)
        let url = try XCTUnwrap(request.url)
        let metadata = DataEgressRequest(
            operation: .dictationPolish,
            destination: DataEgressDestination(url: url),
            dataClassification: .dictationText,
            meetingID: nil,
            consentSource: .dictationPolishMode,
            providerDisclosure: DataEgressProviderDisclosure(providerID: url.host ?? "", modelID: "qwen-local"))
        return (request, metadata)
    }

    private func polishEvent(meetingID: MeetingID? = nil) -> DataEgressEvent {
        DataEgressEvent(
            meetingID: meetingID,
            operation: .dictationPolish,
            destinationScope: .localDevice,
            destinationHost: "localhost",
            dataClassification: .dictationText,
            consentSource: .dictationPolishMode,
            providerID: "localhost",
            modelID: "qwen-local",
            attemptedAt: now)
    }

    private static func insertDictation(
        id: UUID, mode: String, text: String = "Hola.", at date: Date, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO dictationRecord (
                    id, createdAt, durationMs, text, originalText, mode, language,
                    engine, applicationName, applicationBundleID, delivery)
                VALUES (?, ?, 1000, ?, NULL, ?, 'es', 'parakeet', 'Notes', NULL, 'verified')
                """,
            arguments: [id.uuidString, date, text, mode])
    }
}
