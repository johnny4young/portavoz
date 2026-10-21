import ApplicationKit
import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit
import XCTest

@testable import portavoz_cli

/// The dictation MCP tools against a real in-memory store: the agent consent
/// is rechecked on every call and the meeting catalog stays a frozen prefix.
final class DictationToolboxTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDictationToolsAreAppendedAfterTheFrozenMeetingCatalog() throws {
        let tools = DictationToolbox.tools(reader: .local(store: try MeetingStore.inMemory()))
        XCTAssertEqual(tools.map(\.name), ["list_dictations", "search_dictations", "get_dictation"])
        for tool in tools {
            let schema = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8)) as? [String: Any], tool.name)
            XCTAssertEqual(schema["type"] as? String, "object", tool.name)
        }
        XCTAssertTrue(MeetingToolbox.serverInstructions.contains("only while the user allows it"))
    }

    func testEveryToolRefusesUntilTheUserSharesTheHistoryAndAgainAfterRevoking() async throws {
        let store = try await populatedStore(sharing: false)
        let tools = DictationToolbox.tools(reader: .local(store: store))
        let id = try await anyID(store)

        for (name, arguments) in [
            ("list_dictations", "{}"), ("search_dictations", #"{"query":"notas"}"#),
            ("get_dictation", #"{"id":"\#(id)"}"#)
        ] {
            let answer = try await call(tools, name, arguments)
            XCTAssertEqual(answer, DictationToolbox.notAllowed, name)
        }

        _ = try await store.setDictationHistoryPolicy(
            isEnabled: true, keepsOriginal: true, retentionDays: 30, exposesToAgents: true, at: now)
        let shared = try await call(tools, "list_dictations", "{}")
        XCTAssertTrue(shared.hasPrefix("portavoz-dictations/1 total=3"))

        _ = try await store.setDictationHistoryPolicy(
            isEnabled: false, keepsOriginal: true, retentionDays: 30, exposesToAgents: true, at: now)
        _ = try await store.setDictationHistoryPolicy(
            isEnabled: true, keepsOriginal: true, retentionDays: 30, at: now)
        let afterHistoryOff = try await call(tools, "list_dictations", "{}")
        XCTAssertEqual(afterHistoryOff, DictationToolbox.notAllowed, "turning history off withdraws agent access")
    }

    func testListPagesDescribeThemselvesWithAContentFreeHeader() async throws {
        let tools = DictationToolbox.tools(reader: .local(store: try await populatedStore(sharing: true)))

        let first = try await call(tools, "list_dictations", #"{"limit":2}"#)
        let header = try XCTUnwrap(first.split(separator: "\n").first)
        XCTAssertEqual(header, "portavoz-dictations/1 total=3 range=1-2 next_offset=2")
        XCTAssertTrue(first.contains("Notes · inserted · clean\n  No borres estas notas."))
        XCTAssertTrue(first.contains("Slack · not delivered · literal"))

        let last = try await call(tools, "list_dictations", #"{"offset":2,"limit":999}"#)
        XCTAssertTrue(last.hasPrefix("portavoz-dictations/1 total=3 range=3-3 next_offset=none"))
        XCTAssertTrue(last.contains("Mail · inserted · literal\n  Revisa la acción pendiente."))

        let past = try await call(tools, "list_dictations", #"{"offset":9}"#)
        XCTAssertTrue(past.hasSuffix("Offset is past the end."))
    }

    func testSearchFiltersBeforePagingAndTreatsSyntaxAsText() async throws {
        let tools = DictationToolbox.tools(reader: .local(store: try await populatedStore(sharing: true)))

        let accent = try await call(tools, "search_dictations", #"{"query":"accion"}"#)
        XCTAssertTrue(accent.hasPrefix("portavoz-dictations/1 total=1"))
        XCTAssertTrue(accent.contains("Revisa la acción pendiente."))

        let undelivered = try await call(
            tools, "search_dictations", #"{"query":"report","only_not_delivered":true,"application":"Slack"}"#)
        XCTAssertTrue(undelivered.hasPrefix("portavoz-dictations/1 total=1"))

        for hostile in [#"\""#, "*", "NEAR(a b)", "text:report", "report OR notas"] {
            let answer = try await call(tools, "search_dictations", #"{"query":"\#(hostile)"}"#)
            XCTAssertTrue(answer.hasPrefix("portavoz-dictations/1 total="), hostile)
        }
    }

    func testGetDictationReturnsTheFullTextAndTheKeptOriginal() async throws {
        let store = try await populatedStore(sharing: true)
        let tools = DictationToolbox.tools(reader: .local(store: store))
        let notes = try await store.dictationRecords(matching: .init(query: "notas"), limit: 1)
        let id = try XCTUnwrap(notes.first).id.rawValue.uuidString

        let detail = try await call(tools, "get_dictation", #"{"id":"\#(id)"}"#)
        XCTAssertTrue(detail.hasPrefix("portavoz-dictations/1 id=\(id)"))
        XCTAssertTrue(detail.contains("Text:\n  No borres estas notas."))
        XCTAssertTrue(detail.contains("Before Clean mode:\n  eh no borres estas notas"))

        let unknown = try await call(tools, "get_dictation", #"{"id":"\#(UUID().uuidString)"}"#)
        XCTAssertTrue(unknown.hasSuffix("No such dictation."))
        do {
            _ = try await call(tools, "get_dictation", #"{"id":"not-a-uuid"}"#)
            XCTFail("a malformed id must be rejected")
        } catch DictationToolbox.ToolboxError.badDictationID {}
    }

    func testLongTextsArePreviewedInListsButNeverInTheHeader() {
        let long = String(repeating: "palabra ", count: 100)
        let record = DictationRecord(
            id: DictationRecordID(), createdAt: now, duration: 30, text: long, originalText: nil,
            mode: .literal, language: nil, engine: "parakeet", applicationName: "Zed",
            applicationBundleID: nil, delivery: .dispatched)
        let page = DictationToolbox.render(.allowed(DictationRecordPage(total: 1, offset: 0, records: [record])))
        let header = page.split(separator: "\n").first.map(String.init) ?? ""

        XCTAssertFalse(header.contains("palabra"), "the header carries no content")
        XCTAssertTrue(page.contains("(get_dictation for the full text)"))
        XCTAssertTrue(page.contains("sent, not verified"))
    }

    private func populatedStore(sharing: Bool) async throws -> MeetingStore {
        let store = try MeetingStore.inMemory()
        let policy = try await store.setDictationHistoryPolicy(
            isEnabled: true, keepsOriginal: true, retentionDays: 30, exposesToAgents: sharing, at: now)
        let samples: [(String, String?, String, DictationRecordDelivery)] = [
            ("No borres estas notas.", "eh no borres estas notas", "Notes", .verified),
            ("Send the report on Friday.", nil, "Slack", .notDelivered),
            ("Revisa la acción pendiente.", nil, "Mail", .verified)
        ]
        for (offset, sample) in samples.enumerated() {
            _ = try await store.recordDictation(
                DictationRecord(
                    id: DictationRecordID(), createdAt: now.addingTimeInterval(Double(-offset) * 60),
                    duration: 3, text: sample.0, originalText: sample.1, mode: sample.1 == nil ? .literal : .clean,
                    language: nil, engine: "parakeet", applicationName: sample.2, applicationBundleID: nil,
                    delivery: sample.3),
                admittedGeneration: policy.generation, at: now)
        }
        return store
    }

    private func anyID(_ store: MeetingStore) async throws -> String {
        let newest = try await store.dictationRecords(limit: 1)
        return try XCTUnwrap(newest.first).id.rawValue.uuidString
    }

    private func call(_ tools: [MCPTool], _ name: String, _ arguments: String) async throws -> String {
        let tool = try XCTUnwrap(tools.first { $0.name == name }, name)
        return try await tool.handler(Data(arguments.utf8))
    }
}
