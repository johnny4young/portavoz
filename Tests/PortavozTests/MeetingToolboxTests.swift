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
    func testCatalogFreezesTheSixV1ToolsAndAppendsTheReadingV2Tools() throws {
        let tools = MeetingToolbox.tools(
            library: QueryMeetingLibrary(reader: ToolboxReaderFake()),
            ask: askFake())
        // portavoz-reading/2: the original six stay an ordered prefix so
        // existing consumers keep addressing exactly what they always did.
        XCTAssertEqual(
            Array(tools.map(\.name).prefix(6)),
            [
                "list_meetings", "search_meetings", "get_transcript",
                "get_summary", "ask", "get_action_items"
            ])
        XCTAssertEqual(
            Array(tools.map(\.name).dropFirst(6)),
            ["get_transcript_v2", "get_summary_v2", "get_action_items_v2"])
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

    // MARK: - portavoz-reading/2

    /// The frozen contract in action: v1 must keep serving the pre-correction
    /// accepted text on a corrected meeting, while v2 serves the corrected
    /// reading and says so in its header.
    func testV1TranscriptStillServesAcceptedTextOnACorrectedMeeting() {
        let detail = correctedDetailFixture()

        let v1 = MeetingToolbox.transcriptPage(detail: detail, offset: 0, limit: 10)
        XCTAssertTrue(v1.contains("texto original"), "v1 keeps the accepted text")
        XCTAssertFalse(v1.contains("texto corregido"), "v1 never composes")
        XCTAssertFalse(v1.contains("portavoz-reading/2"), "v1 output is frozen")
    }

    func testTranscriptV2ServesTheComposedReadingWithItsHeader() {
        let detail = correctedDetailFixture()

        let v2 = MeetingToolbox.composedTranscriptPage(
            detail: detail, offset: 0, limit: 10)
        let header = v2.components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(header.hasPrefix("portavoz-reading/2 meeting="))
        XCTAssertTrue(header.contains(" base=0 "))
        XCTAssertTrue(header.contains(" reading=composed composed=current"))
        let correctionField = header.components(separatedBy: " correction=")
            .dropFirst().first?.components(separatedBy: " ").first ?? ""
        XCTAssertEqual(correctionField.count, 16, "a truncated content hash")
        XCTAssertTrue(v2.contains("texto corregido"))
        XCTAssertFalse(
            v2.contains("texto original"),
            "the replaced text does not appear as current")
    }

    func testTranscriptV2FailsClosedWhenCompositionCannotServe() {
        // A correction targeting a segment the meeting does not have: the
        // composer refuses, and v2 must downgrade honestly instead of
        // serving partial corrected text.
        let detail = correctedDetailFixture(
            correctionTarget: UUID(
                uuidString: "AAAAAAAA-0000-4000-8000-000000000000")!)

        let v2 = MeetingToolbox.composedTranscriptPage(
            detail: detail, offset: 0, limit: 10)
        let header = v2.components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(header.contains(" reading=accepted composed=pending"))
        XCTAssertTrue(v2.contains("texto original"), "the accepted body still serves")
        XCTAssertFalse(v2.contains("texto corregido"))
    }

    func testTranscriptV2OnAnUncorrectedMeetingReadsAcceptedCurrent() {
        let detail = detailFixture(segmentCount: 2)

        let v2 = MeetingToolbox.composedTranscriptPage(
            detail: detail, offset: 0, limit: 10)
        let header = v2.components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(header.contains(" correction=accepted"))
        XCTAssertTrue(header.contains(" reading=accepted composed=current"))
        XCTAssertTrue(v2.contains("row 1"))
    }

    func testGeneratedArtifactStalenessDisclosesPendingCorrections() {
        let corrected = correctedDetailFixture()
        XCTAssertEqual(
            MeetingToolbox.generatedArtifactComposedState(corrected),
            "pending",
            "a legacy summary on a corrected meeting predates the corrections")

        // Same meeting, provenance recorded from its own active corrections.
        let current = MeetingLibraryDetail(
            meeting: corrected.meeting,
            speakers: corrected.speakers,
            segments: corrected.segments,
            corrections: corrected.corrections,
            summary: corrected.summary,
            summaryVersion: corrected.summaryVersion,
            summaryCorrectionSource: .revision(corrected.correctionRevision))
        XCTAssertEqual(
            MeetingToolbox.generatedArtifactComposedState(current),
            "current",
            "a summary generated from the active corrections is current")

        let uncorrected = detailFixture(segmentCount: 1)
        XCTAssertEqual(
            MeetingToolbox.generatedArtifactComposedState(uncorrected), "current")
    }

    func testActionItemsV2ServesOneMeetingsItemsBehindTheHeader() async throws {
        let detail = correctedDetailFixture(withSummary: true)
        let tools = MeetingToolbox.tools(
            library: QueryMeetingLibrary(reader: ToolboxReaderFake(detail: detail)),
            ask: askFake())
        let tool = try XCTUnwrap(tools.first { $0.name == "get_action_items_v2" })

        let response = try await tool.handler(Data(
            #"{"meeting_id":"\#(detail.meeting.id.rawValue.uuidString)"}"#.utf8))
        let header = response.components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(header.hasPrefix("portavoz-reading/2 meeting="))
        XCTAssertTrue(header.contains(" reading=accepted composed=pending"))
        XCTAssertTrue(response.contains("- [ ] Enviar el acta"))
    }

    // MARK: - Fixtures

    private func correctedDetailFixture(
        correctionTarget: UUID? = nil,
        summaryCorrectionSource: TranscriptCorrectionArtifactSource = .legacyAccepted,
        withSummary: Bool = false
    ) -> MeetingLibraryDetail {
        let base = detailFixture(segmentCount: 2)
        let meeting = base.meeting
        var segments = base.segments
        segments[0] = TranscriptSegment(
            id: segments[0].id,
            meetingID: meeting.id,
            speakerID: segments[0].speakerID,
            channel: .system,
            text: "el texto original de la reunión",
            startTime: segments[0].startTime,
            endTime: segments[0].endTime,
            isFinal: true)
        let correction = TranscriptCorrectionEvent(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000201")!,
            meetingID: meeting.id,
            baseTranscriptRevision: meeting.transcriptRevision,
            targetSegmentIDs: [correctionTarget ?? segments[0].id],
            kind: .replaceText(text: "el texto corregido de la reunión", language: "es"),
            sourceDeviceID: UUID(uuidString: "00000000-0000-4000-9000-000000000003")!,
            createdAt: Date(timeIntervalSince1970: 400))
        return MeetingLibraryDetail(
            meeting: meeting,
            speakers: base.speakers,
            segments: segments,
            corrections: [correction],
            summary: withSummary ? SummaryDraft(
                meetingID: meeting.id,
                recipeID: "general",
                language: "es",
                markdown: "## Resumen",
                actionItems: [ActionItem(text: "Enviar el acta")]) : nil,
            summaryVersion: withSummary ? 1 : nil,
            summaryCorrectionSource: summaryCorrectionSource)
    }

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
    private let detail: MeetingLibraryDetail?

    init(detail: MeetingLibraryDetail? = nil) {
        self.detail = detail
    }

    func meetingLibraryMeetings(limit: Int?) -> [Meeting] {
        _ = limit
        return []
    }

    func meetingLibraryDetail(_ id: MeetingID) -> MeetingLibraryDetail? {
        guard let detail, detail.meeting.id == id else { return nil }
        return detail
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
