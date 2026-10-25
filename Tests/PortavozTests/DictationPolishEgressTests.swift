import Foundation
import GRDB
@testable import IntegrationsKit
@testable import IntelligenceKit
import PortavozCore
@testable import StorageKit
import XCTest

final class DictationPolishEgressTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testGatewayAcceptsDictationPolishOnlyOnLoopback() throws {
        let (request, metadata) = try polishRequest(endpoint: OllamaService.openAIEndpoint)
        XCTAssertNoThrow(try URLSessionDataEgressGateway.validate(request, metadata: metadata))

        for host in ["http://127.0.0.1:11434/v1", "http://[::1]:11434/v1"] {
            let (loopback, loopbackMetadata) = try polishRequest(endpoint: try XCTUnwrap(URL(string: host)))
            XCTAssertNoThrow(try URLSessionDataEgressGateway.validate(loopback, metadata: loopbackMetadata), host)
        }
        for host in ["http://192.168.1.20:11434/v1", "https://api.example.com/v1", "http://ollama.local:11434/v1"] {
            let (remote, remoteMetadata) = try polishRequest(endpoint: try XCTUnwrap(URL(string: host)))
            XCTAssertThrowsError(try URLSessionDataEgressGateway.validate(remote, metadata: remoteMetadata)) { error in
                XCTAssertEqual(
                    error as? DataEgressGatewayError,
                    .invalidMetadata("Dictation polish requires a loopback destination"),
                    host)
            }
        }
    }

    func testGatewayRejectsForgedDictationPolishMetadata() throws {
        let (request, valid) = try polishRequest(endpoint: OllamaService.openAIEndpoint)
        let forged: [(DataEgressRequest, String)] = [
            (valid.with(meetingID: MeetingID()), "Dictation polish never carries a meeting identity"),
            (valid.with(consent: .summaryEngineSettings), "Dictation polish requires Polish-mode consent"),
            (valid.with(classification: .meetingAnswerMaterial),
             "Dictation polish egress requires a classified non-empty model POST"),
            (valid.with(operation: .askAnswerGeneration, classification: .dictationText),
             "Ask answer generation requires answer-only material"),
            (valid.with(operation: .summaryGeneration, classification: .dictationText),
             "Summary egress requires a classified non-empty model POST"),
        ]
        for (metadata, message) in forged {
            XCTAssertThrowsError(try URLSessionDataEgressGateway.validate(request, metadata: metadata)) { error in
                XCTAssertEqual(error as? DataEgressGatewayError, .invalidMetadata(message))
            }
        }
    }

    func testGlobalJournalKeepsAContentFreePolishReceipt() async throws {
        let store = try MeetingStore.inMemory()
        let event = polishEvent()

        try await store.recordDataEgressEvent(event)
        let events = try await store.globalDataEgressEvents()

        XCTAssertEqual(events, [event])
        XCTAssertNil(events.first?.meetingID)
    }

    func testGlobalJournalRejectsPolishReceiptsOutsideTheLocalContract() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Weekly", startedAt: now)
        try await store.save(meeting)
        let invalid = [
            polishEvent(classification: .meetingAnswerMaterial),
            polishEvent(consent: .summaryEngineSettings),
            polishEvent(modelID: " "),
            polishEvent(modelID: nil),
            polishEvent(host: "192.168.1.20"),
        ]
        for event in invalid {
            do {
                try await store.recordDataEgressEvent(event)
                XCTFail("an out-of-contract polish receipt must fail: \(event)")
            } catch {}
        }
        do {
            try await store.recordDataEgressEvent(polishEvent(meetingID: meeting.id))
            XCTFail("a polish receipt never belongs to a meeting")
        } catch {}

        let global = try await store.globalDataEgressEvents()
        let owned = try await store.dataEgressEvents(for: meeting.id)
        XCTAssertTrue(global.isEmpty)
        XCTAssertTrue(owned.isEmpty)
    }

    func testV59AdmitsPolishInHistoryAndJournalWithoutLosingSearchOrMeetingLinks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-polish-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = self.now
        let dictationID = DictationRecordID()
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
                arguments: [dictationID.rawValue.uuidString, meeting.id.rawValue.uuidString, note.id.uuidString, now])
            try GlobalDataEgressEventRecord(askReceipt, modelID: "qwen-local").insert(db)
            XCTAssertThrowsError(try Self.insertDictation(id: DictationRecordID(), mode: "polish", at: now, in: db))
        }
        try legacy.close()

        let store = try MeetingStore(databaseURL: url)
        let found = try await store.dictationRecords(matching: DictationRecordFilter(query: "presupuesto"), limit: 10)
        let links = try await store.dictationMeetingLinks(for: [dictationID])
        try await store.recordDataEgressEvent(polishEvent())
        let journal = try await store.globalDataEgressEvents()

        XCTAssertEqual(found.map(\.id), [dictationID])
        XCTAssertEqual(links[dictationID]?.map(\.title), ["Weekly"])
        XCTAssertEqual(journal.map(\.operation), [.askAnswerGeneration, .dictationPolish])
        try await store.database.write { db in
            XCTAssertNoThrow(try Self.insertDictation(id: DictationRecordID(), mode: "polish", at: now, in: db))
            XCTAssertThrowsError(try Self.insertDictation(id: DictationRecordID(), mode: "fancy", at: now, in: db))
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

    func testHistoryRoundTripsAPolishedDictation() async throws {
        let store = try MeetingStore.inMemory()
        let policy = try await store.setDictationHistoryPolicy(
            isEnabled: true, keepsOriginal: true, retentionDays: 30, at: now)
        let record = DictationRecord(
            id: DictationRecordID(), createdAt: now, duration: 3, text: "Mañana enviamos el informe.",
            originalText: "eh mañana enviamos el informe", mode: .polish, language: "es", engine: "parakeet",
            applicationName: "Slack", applicationBundleID: "com.tinyspeck.slackmacgap", delivery: .verified)

        let outcome = try await store.recordDictation(record, admittedGeneration: policy.generation, at: now)
        let saved = try await store.dictationRecords(limit: 10)

        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(saved, [record])
    }

    private func polishRequest(endpoint: URL) throws -> (URLRequest, DataEgressRequest) {
        let request = try OpenAICompatibleChatCodec.urlRequest(
            endpoint: endpoint, model: "qwen-local", apiKey: "ollama",
            system: DictationPolishPrompt.instructions, user: "<dictation>\nhola\n</dictation>",
            temperature: 0, maxTokens: 64)
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

    private func polishEvent(
        meetingID: MeetingID? = nil,
        host: String = "localhost",
        classification: DataEgressClassification = .dictationText,
        consent: DataEgressConsentSource = .dictationPolishMode,
        modelID: String? = "qwen-local"
    ) -> DataEgressEvent {
        DataEgressEvent(
            meetingID: meetingID,
            operation: .dictationPolish,
            destinationScope: DataEgressDestination.scope(forHost: host),
            destinationHost: host,
            dataClassification: classification,
            consentSource: consent,
            providerID: host,
            modelID: modelID,
            attemptedAt: now)
    }

    private static func insertDictation(
        id: DictationRecordID, mode: String, text: String = "Hola.", at date: Date, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO dictationRecord (
                    id, createdAt, durationMs, text, originalText, mode, language,
                    engine, applicationName, applicationBundleID, delivery)
                VALUES (?, ?, 1000, ?, NULL, ?, 'es', 'parakeet', 'Notes', NULL, 'verified')
                """,
            arguments: [id.rawValue.uuidString, date, text, mode])
    }
}

private extension DataEgressRequest {
    func with(
        operation: DataEgressOperation? = nil,
        classification: DataEgressClassification? = nil,
        meetingID: MeetingID? = nil,
        consent: DataEgressConsentSource? = nil
    ) -> DataEgressRequest {
        DataEgressRequest(
            operation: operation ?? self.operation,
            destination: destination,
            dataClassification: classification ?? dataClassification,
            meetingID: meetingID ?? self.meetingID,
            consentSource: consent ?? consentSource,
            providerDisclosure: providerDisclosure)
    }
}
