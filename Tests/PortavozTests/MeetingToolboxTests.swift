import ApplicationKit
import Foundation
import IntegrationsKit
import PortavozCore
import XCTest

@testable import portavoz_cli

/// The real MCP tools (not the protocol fakes in `MCPServerTests`): the
/// catalog shape, argument defaults and bounds, and — above all — the
/// self-describing transcript pagination the read-only server promises in
/// its instructions.
final class MeetingToolboxTests: XCTestCase {
    func testCatalogExposesTheSixReadOnlyToolsWithParseableSchemas() throws {
        let tools = MeetingToolbox.tools(
            library: QueryMeetingLibrary(reader: ToolboxReaderFake()),
            ask: askFake())
        XCTAssertEqual(
            tools.map(\.name),
            [
                "list_meetings", "search_meetings", "get_transcript",
                "get_summary", "ask", "get_action_items"
            ])
        for tool in tools {
            let schema = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: Data(tool.inputSchema.utf8)) as? [String: Any],
                tool.name)
            XCTAssertEqual(schema["type"] as? String, "object", tool.name)
        }
    }

    func testServerInstructionsDeclareTheReadOnlyContract() {
        XCTAssertTrue(MeetingToolbox.serverInstructions.contains("read-only"))
        XCTAssertTrue(
            MeetingToolbox.serverInstructions.contains("nothing here can create"))
        XCTAssertTrue(MeetingToolbox.serverInstructions.contains("paginated"))
    }

    func testTranscriptPaginationDescribesItselfAndNeverOverlaps() {
        let detail = detailFixture(segmentCount: 5)

        let first = MeetingToolbox.transcriptPage(detail: detail, offset: 0, limit: 2)
        XCTAssertTrue(first.hasPrefix("Segments 1-2 of 5. Pass offset=2 for the next page."))
        XCTAssertTrue(first.contains("row 1"))
        XCTAssertTrue(first.contains("row 2"))
        XCTAssertFalse(first.contains("row 3"), "a page must stop at its limit")

        let second = MeetingToolbox.transcriptPage(detail: detail, offset: 2, limit: 2)
        XCTAssertTrue(second.contains("row 3"))
        XCTAssertFalse(second.contains("row 2"), "pages must not overlap")

        let last = MeetingToolbox.transcriptPage(detail: detail, offset: 4, limit: 2)
        XCTAssertTrue(last.hasPrefix("Segments 5-5 of 5. Transcript complete."))
    }

    func testTranscriptPaginationBoundsAreClampedNotTrusted() {
        let detail = detailFixture(segmentCount: 3)

        // Past the end: an honest answer, not an error or an empty blob.
        XCTAssertEqual(
            MeetingToolbox.transcriptPage(detail: detail, offset: 9, limit: 2),
            "Segments 3 total; offset 9 is past the end.")
        // A negative offset reads from the start; limit 0 still yields one row.
        let clamped = MeetingToolbox.transcriptPage(detail: detail, offset: -4, limit: 0)
        XCTAssertTrue(clamped.hasPrefix("Segments 1-1 of 3."))
        // The cap holds even when the client asks for more.
        let capped = MeetingToolbox.transcriptPage(
            detail: detailFixture(segmentCount: MeetingToolbox.transcriptPageMaximum + 40),
            offset: 0,
            limit: .max)
        XCTAssertTrue(
            capped.hasPrefix(
                "Segments 1-\(MeetingToolbox.transcriptPageMaximum) of "))
    }

    func testDefaultPageCoversAWholeShortMeetingInOneCall() {
        let detail = detailFixture(segmentCount: 12)
        let page = MeetingToolbox.transcriptPage(
            detail: detail, offset: 0, limit: MeetingToolbox.transcriptPageDefault)
        XCTAssertTrue(page.hasPrefix("Segments 1-12 of 12. Transcript complete."))
    }

    func testSearchToolCapsTheRequestedLimit() async throws {
        let reader = ToolboxReaderFake()
        let tools = MeetingToolbox.tools(
            library: QueryMeetingLibrary(reader: reader),
            ask: askFake())
        let search = try XCTUnwrap(tools.first { $0.name == "search_meetings" })

        _ = try await search.handler(Data(#"{"query":"tema","limit":999}"#.utf8))
        let seen = await reader.lastSearchLimit
        XCTAssertEqual(
            seen, MeetingToolbox.searchLimitMaximum,
            "the boundary must never see an unbounded client limit")

        _ = try await search.handler(Data(#"{"query":"tema"}"#.utf8))
        let defaulted = await reader.lastSearchLimit
        XCTAssertEqual(defaulted, MeetingToolbox.searchLimitDefault)
    }

    // MARK: - Fixtures

    private func detailFixture(segmentCount: Int) -> MeetingLibraryDetail {
        let meetingID = MeetingID()
        let speaker = Speaker(meetingID: meetingID, label: "S1", displayName: "Ana")
        let segments: [TranscriptSegment] = (1...segmentCount).map { index in
            let start = TimeInterval(index * 5)
            let text = "Contenido de la fila row \(index) con palabras."
            return TranscriptSegment(
                meetingID: meetingID,
                speakerID: speaker.id,
                channel: .system,
                text: text,
                startTime: start,
                endTime: start + 4,
                isFinal: true)
        }
        return MeetingLibraryDetail(
            meeting: Meeting(
                id: meetingID,
                title: "Reunión de prueba",
                startedAt: Date(timeIntervalSince1970: 100),
                endedAt: Date(timeIntervalSince1970: 700),
                language: "es"),
            speakers: [speaker],
            segments: segments,
            summary: nil,
            summaryVersion: nil)
    }

    private func askFake() -> AskMeetings {
        AskMeetings(
            retrieval: ToolboxRetrieverFake(),
            answering: ToolboxAnswererFake())
    }
}

private actor ToolboxReaderFake: MeetingLibraryQueryReading {
    private(set) var lastSearchLimit: Int?

    func meetingLibraryMeetings(limit: Int?) -> [Meeting] {
        _ = limit
        return []
    }

    func meetingLibraryDetail(_ id: MeetingID) -> MeetingLibraryDetail? {
        _ = id
        return nil
    }

    func meetingLibrarySearch(_ query: String, limit: Int) -> [LibrarySearchHit] {
        _ = query
        lastSearchLimit = limit
        return []
    }

    func meetingLibraryOpenItems(limit: Int) -> [LibraryOpenItem] {
        _ = limit
        return []
    }
}

private struct ToolboxRetrieverFake: AskMeetingRetrieving {
    func search(query: String, limit: Int) async throws -> [AskSearchResult] {
        _ = query
        _ = limit
        return []
    }

    func retrieve(question: String, limit: Int) async throws -> [AskCitation] {
        _ = question
        _ = limit
        return []
    }
}

private struct ToolboxAnswererFake: AskMeetingAnswering {
    func answer(question: String, citations: [AskCitation]) async throws -> String? {
        _ = question
        _ = citations
        return nil
    }
}
