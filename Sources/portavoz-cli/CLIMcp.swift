import ApplicationKit
import Foundation
import IntegrationsKit
import IntelligenceKit
import PortavozCore

/// `portavoz-cli mcp [--db <path>]`
///
/// The M8 dev moat: a local MCP server over stdio that lets any agent
/// query the meeting library. Register it with e.g.:
///
///     claude mcp add portavoz -- portavoz-cli mcp
///
/// Everything stays on this machine — the server only speaks through the
/// pipes of the process that launched it.
enum McpCommand {
    static func run(
        _ arguments: [String],
        platform: CLIPlatformDependencies
    ) async {
        var dbPath: String?
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--db", index + 1 < arguments.count {
                dbPath = arguments[index + 1]
                index += 1
            }
            index += 1
        }

        let application: CLIComposition
        do {
            application = try CLIComposition.open(
                dbPath: dbPath,
                platform: platform)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return
        }

        let server = MCPServer(
            instructions: MeetingToolbox.serverInstructions,
            tools: MeetingToolbox.tools(
                library: application.library,
                ask: application.ask))
        while let line = readLine(strippingNewline: true) {
            if let response = await server.handleLine(line) {
                print(response)
                fflush(stdout)
            }
        }
    }
}

/// Application-backed MCP tools. IntegrationsKit owns JSON-RPC transport while
/// this executable retains protocol presentation and localized-free strings.
enum MeetingToolbox {
    /// Transcript pagination bounds: a 200-segment page keeps even a dense
    /// hour readable in a few calls, and the cap stops a client from asking
    /// the library for one multi-megabyte response.
    static let transcriptPageDefault = 200
    static let transcriptPageMaximum = 500
    /// Search results are snippets; beyond this the agent should refine the
    /// query instead of scrolling.
    static let searchLimitDefault = 20
    static let searchLimitMaximum = 50

    /// Sent to clients in the `initialize` response (MCP `instructions`).
    static let serverInstructions = """
        Portavoz is a read-only window into the user's local meeting library. \
        Every tool only reads; nothing here can create, modify, or delete \
        meetings, and all processing stays on this machine. \
        For questions, prefer `ask` (local RAG with citations). Use \
        `get_transcript` for verbatim reading — it is paginated by segment \
        (`offset`/`limit`) and tells you when more remains. \
        `search_meetings` finds moments across all meetings; `list_meetings`, \
        `get_summary`, and `get_action_items` cover the rest. \
        The `portavoz-reading/2` tools are correction-aware: `get_transcript_v2` \
        serves the user-corrected transcript when it is safely composable, and \
        `get_summary_v2` / `get_action_items_v2` disclose whether a generated \
        artifact predates the current corrections. Each v2 response opens with \
        one content-free header line stating what you are reading.
        """

    // MCP tool catalog: one long literal array of definitions,
    // one per tool; splitting it would not improve clarity.
    // swiftlint:disable:next function_body_length
    static func tools(
        library: QueryMeetingLibrary,
        ask: AskMeetings
    ) -> [MCPTool] {
        // JSON schemas and one-line tool descriptions (some inside
        // multiline strings): splitting them would break the content.
        // swiftlint:disable line_length
        [
            MCPTool(
                name: "list_meetings",
                description: "List recent meetings with their ids, titles and dates.",
                inputSchema: """
                    {"type":"object","properties":{"limit":{"type":"integer","description":"Max meetings to return (default 20)"}}}
                    """
            ) { data in
                struct Args: Decodable { var limit: Int? }
                let limit = (try? JSONDecoder().decode(Args.self, from: data))?.limit ?? 20
                let meetings = try await library.meetings(limit: limit)
                guard !meetings.isEmpty else { return "No meetings in the library yet." }
                let formatter = ISO8601DateFormatter()
                return meetings.map {
                    "\($0.id.rawValue.uuidString) · \(formatter.string(from: $0.startedAt)) · \($0.title)"
                }.joined(separator: "\n")
            },

            MCPTool(
                name: "search_meetings",
                description: "Full-text search across every meeting transcript. Returns matching snippets with meeting ids and timestamps.",
                inputSchema: """
                    {"type":"object","properties":{"query":{"type":"string","description":"Words to search for"},"limit":{"type":"integer","description":"Max snippets to return (default 20, max 50)"}},"required":["query"]}
                    """
            ) { data in
                struct Args: Decodable {
                    var query: String
                    var limit: Int?
                }
                let args = try JSONDecoder().decode(Args.self, from: data)
                let limit = min(args.limit ?? searchLimitDefault, searchLimitMaximum)
                let hits = try await library.search(args.query, limit: limit)
                guard !hits.isEmpty else { return "No matches for: \(args.query)" }
                return hits.map {
                    "[\(timestamp($0.startTime))] \($0.meetingTitle) (\($0.meetingID.rawValue.uuidString)): \($0.snippet)"
                }.joined(separator: "\n")
            },

            MCPTool(
                name: "get_transcript",
                description: "Speaker-attributed transcript of one meeting, paginated by segment. The first line reports the covered range and the offset to continue from.",
                inputSchema: """
                    {"type":"object","properties":{"meeting_id":{"type":"string","description":"Meeting UUID"},"offset":{"type":"integer","description":"First segment index to return (default 0)"},"limit":{"type":"integer","description":"Max segments to return (default 200, max 500)"}},"required":["meeting_id"]}
                    """
            ) { data in
                struct Page: Decodable {
                    var offset: Int?
                    var limit: Int?
                }
                let detail = try await detail(from: data, library: library)
                let page = (try? JSONDecoder().decode(Page.self, from: data)) ?? Page()
                return transcriptPage(
                    detail: detail,
                    offset: page.offset ?? 0,
                    limit: page.limit ?? transcriptPageDefault)
            },

            MCPTool(
                name: "get_summary",
                description: "Latest summary snapshot (markdown) of one meeting, including action items.",
                inputSchema: """
                    {"type":"object","properties":{"meeting_id":{"type":"string","description":"Meeting UUID"}},"required":["meeting_id"]}
                    """
            ) { data in
                let detail = try await detail(from: data, library: library)
                guard let draft = detail.summary,
                      let version = detail.summaryVersion
                else {
                    return "The meeting has no summary yet."
                }
                var text = "Summary v\(version) (\(draft.language)) of \(detail.meeting.title):\n\n\(draft.markdown)"
                if !draft.actionItems.isEmpty {
                    text += "\n\nAction items:\n" + draft.actionItems.map {
                        "- [\($0.isDone ? "x" : " ")] \($0.text)"
                    }.joined(separator: "\n")
                }
                return text
            },

            MCPTool(
                name: "ask",
                description: "Answer a natural-language question about the user's meetings using local RAG (hybrid retrieval + on-device model), with citations. E.g. 'what did I agree to yesterday?'.",
                inputSchema: """
                    {"type":"object","properties":{"question":{"type":"string","description":"The question, any language"}},"required":["question"]}
                    """
            ) { data in
                struct Args: Decodable { var question: String }
                let args = try JSONDecoder().decode(Args.self, from: data)
                let result = try await ask.answer(
                    args.question,
                    source: .library,
                    limit: 6)
                guard !result.citations.isEmpty else {
                    return "Nothing related found in the meeting library."
                }
                let sources = result.citations.enumerated().map { index, citation in
                    "[\(index + 1)] \(citation.meetingTitle) · \(timestamp(citation.timestamp)) · \(citation.text)"
                }.joined(separator: "\n")
                if let answer = result.generatedText {
                    return "\(answer)\n\nSources:\n\(sources)"
                }
                return "Most relevant passages (no on-device model available):\n\(sources)"
            },

            MCPTool(
                name: "get_action_items",
                description: "Pending (unchecked) action items across all meetings, newest first.",
                inputSchema: """
                    {"type":"object","properties":{"limit":{"type":"integer","description":"Max items (default 50)"}}}
                    """
            ) { data in
                struct Args: Decodable { var limit: Int? }
                let limit = (try? JSONDecoder().decode(Args.self, from: data))?.limit ?? 50
                let items = try await library.openItems(limit: limit)
                guard !items.isEmpty else { return "No pending action items." }
                return items.map { "- \($0.item.text) (\($0.meetingTitle))" }.joined(separator: "\n")
            },

            // portavoz-reading/2 (T28b/D313): the six tools above are frozen;
            // correction-aware reads are appended so existing consumers keep
            // their exact accepted-only responses.
            MCPTool(
                name: "get_transcript_v2",
                description: "Corrected transcript of one meeting under the portavoz-reading/2 contract: serves the user's active text corrections when they compose safely, and falls back to the accepted transcript — always saying which one you got in the header line.",
                inputSchema: """
                    {"type":"object","properties":{"meeting_id":{"type":"string","description":"Meeting UUID"},"offset":{"type":"integer","description":"First row index to return (default 0)"},"limit":{"type":"integer","description":"Max rows to return (default 200, max 500)"}},"required":["meeting_id"]}
                    """
            ) { data in
                struct Page: Decodable {
                    var offset: Int?
                    var limit: Int?
                }
                let detail = try await detail(from: data, library: library)
                let page = (try? JSONDecoder().decode(Page.self, from: data)) ?? Page()
                return composedTranscriptPage(
                    detail: detail,
                    offset: page.offset ?? 0,
                    limit: page.limit ?? transcriptPageDefault)
            },

            MCPTool(
                name: "get_summary_v2",
                description: "Latest summary snapshot of one meeting with correction provenance: the portavoz-reading/2 header says whether the summary still matches the user's current transcript corrections (composed=current) or predates them (composed=pending).",
                inputSchema: """
                    {"type":"object","properties":{"meeting_id":{"type":"string","description":"Meeting UUID"}},"required":["meeting_id"]}
                    """
            ) { data in
                let detail = try await detail(from: data, library: library)
                let header = readingHeader(
                    detail: detail,
                    reading: "accepted",
                    composed: generatedArtifactComposedState(detail))
                guard let draft = detail.summary,
                      let version = detail.summaryVersion
                else {
                    return header + "\n\nThe meeting has no summary yet."
                }
                var text = "Summary v\(version) (\(draft.language)) of \(detail.meeting.title):\n\n\(draft.markdown)"
                if !draft.actionItems.isEmpty {
                    text += "\n\nAction items:\n" + draft.actionItems.map {
                        "- [\($0.isDone ? "x" : " ")] \($0.text)"
                    }.joined(separator: "\n")
                }
                return header + "\n\n" + text
            },

            MCPTool(
                name: "get_action_items_v2",
                description: "Action items of one meeting's latest summary with correction provenance: the portavoz-reading/2 header says whether they still match the user's current transcript corrections (composed=current) or predate them (composed=pending).",
                inputSchema: """
                    {"type":"object","properties":{"meeting_id":{"type":"string","description":"Meeting UUID"}},"required":["meeting_id"]}
                    """
            ) { data in
                let detail = try await detail(from: data, library: library)
                let header = readingHeader(
                    detail: detail,
                    reading: "accepted",
                    composed: generatedArtifactComposedState(detail))
                guard let draft = detail.summary, !draft.actionItems.isEmpty else {
                    return header + "\n\nThe meeting's summary has no action items yet."
                }
                let items = draft.actionItems.map {
                    "- [\($0.isDone ? "x" : " ")] \($0.text)"
                }.joined(separator: "\n")
                return header + "\n\n" + items
            }
        ]
        // swiftlint:enable line_length
    }

    enum ToolboxError: Error, LocalizedError {
        case badMeetingID
        case meetingNotFound

        var errorDescription: String? {
            switch self {
            case .badMeetingID: return "meeting_id must be a UUID"
            case .meetingNotFound: return "no such meeting"
            }
        }
    }

    /// One transcript page. The header makes the pagination self-describing
    /// so an agent never has to guess whether more remains: it names the
    /// covered segment range, the total, and the exact offset to continue
    /// from (or that the transcript is complete).
    static func transcriptPage(
        detail: MeetingLibraryDetail,
        offset: Int,
        limit: Int
    ) -> String {
        let total = detail.segments.count
        guard total > 0 else { return "The meeting has no transcript." }
        let start = max(0, offset)
        guard start < total else {
            return "Segments \(total) total; offset \(offset) is past the end."
        }
        let size = min(max(1, limit), transcriptPageMaximum)
        let end = min(start + size, total)
        let body = TranscriptFormatter.format(
            segments: Array(detail.segments[start..<end]),
            speakers: detail.speakers)
        let header = end < total
            ? "Segments \(start + 1)-\(end) of \(total). Pass offset=\(end) for the next page."
            : "Segments \(start + 1)-\(end) of \(total). Transcript complete."
        return header + "\n\n" + body
    }

    /// One content-free line — UUIDs, integers, enums, and a truncated
    /// content-addressed hash only — that tells the agent exactly which
    /// reading it received. Meeting content never enters the header.
    static func readingHeader(
        detail: MeetingLibraryDetail,
        reading: String,
        composed: String
    ) -> String {
        let revision = detail.correctionRevision
        let correction = revision.isAccepted
            ? "accepted"
            : revision == .unavailable
                ? "unavailable"
                : String(revision.rawValue.prefix(16))
        return "portavoz-reading/2"
            + " meeting=\(detail.meeting.id.rawValue.uuidString)"
            + " base=\(detail.meeting.transcriptRevision)"
            + " correction=\(correction)"
            + " reading=\(reading)"
            + " composed=\(composed)"
    }

    /// A generated artifact is `current` only when its recorded correction
    /// lineage matches the corrections active right now; anything else —
    /// legacy artifacts on a corrected meeting, malformed provenance — is
    /// `pending` (fail closed).
    static func generatedArtifactComposedState(
        _ detail: MeetingLibraryDetail
    ) -> String {
        switch detail.summaryCorrectionSource {
        case .revision(let source):
            return source == detail.correctionRevision ? "current" : "pending"
        case .legacyAccepted:
            return detail.correctionRevision.isAccepted ? "current" : "pending"
        case .invalid:
            return "pending"
        }
    }

    /// The composed transcript page behind `get_transcript_v2`. Fail closed:
    /// corrected text is served only when the full composition succeeds
    /// against the current revision — any doubt downgrades to the accepted
    /// reading and says so in the header (`reading=accepted composed=pending`).
    static func composedTranscriptPage(
        detail: MeetingLibraryDetail,
        offset: Int,
        limit: Int
    ) -> String {
        if detail.correctionRevision.isAccepted {
            return readingHeader(detail: detail, reading: "accepted", composed: "current")
                + "\n\n" + transcriptPage(detail: detail, offset: offset, limit: limit)
        }
        let currentCorrections = detail.corrections.filter {
            $0.baseTranscriptRevision == detail.meeting.transcriptRevision
        }
        guard detail.correctionRevision != .unavailable,
              let composition = try? ComposeTranscript().execute(
                  baseTranscriptRevision: detail.meeting.transcriptRevision,
                  baseMaterial: detail.isRefinedTranscript ? .refined : .raw,
                  segments: detail.segments,
                  corrections: currentCorrections)
        else {
            return readingHeader(detail: detail, reading: "accepted", composed: "pending")
                + "\n\n" + transcriptPage(detail: detail, offset: offset, limit: limit)
        }
        return readingHeader(detail: detail, reading: "composed", composed: "current")
            + "\n\n" + composedRowsPage(
                rows: composition.composed.rows,
                speakers: detail.speakers,
                offset: offset,
                limit: limit)
    }

    /// Pagination over composed rows, mirroring `transcriptPage` except that
    /// totals count composed rows — a split or merge legitimately changes the
    /// row count relative to v1.
    static func composedRowsPage(
        rows: [MeetingTranscriptContent.Row],
        speakers: [Speaker],
        offset: Int,
        limit: Int
    ) -> String {
        let total = rows.count
        guard total > 0 else { return "The meeting has no transcript." }
        let start = max(0, offset)
        guard start < total else {
            return "Rows \(total) total; offset \(offset) is past the end."
        }
        let size = min(max(1, limit), transcriptPageMaximum)
        let end = min(start + size, total)
        let labelsByID = Dictionary(
            speakers.map { ($0.id, $0.displayName ?? $0.label) },
            uniquingKeysWith: { first, _ in first })
        let body: String = rows[start..<end]
            .filter { TranscriptContentPolicy.hasLexicalContent($0.text) }
            .map { row in
                let label = row.speakerID.flatMap { labelsByID[$0] }
                    ?? "\(row.channel.rawValue)?"
                return "[\(timestamp(row.startTime))] \(label): \(row.text)"
            }
            .joined(separator: "\n")
        let header = end < total
            ? "Rows \(start + 1)-\(end) of \(total). Pass offset=\(end) for the next page."
            : "Rows \(start + 1)-\(end) of \(total). Transcript complete."
        return header + "\n\n" + body
    }

    private static func detail(
        from data: Data,
        library: QueryMeetingLibrary
    ) async throws -> MeetingLibraryDetail {
        struct Args: Decodable { var meeting_id: String }
        guard
            let args = try? JSONDecoder().decode(Args.self, from: data),
            let uuid = UUID(uuidString: args.meeting_id)
        else { throw ToolboxError.badMeetingID }
        guard let detail = try await library.detail(MeetingID(rawValue: uuid)) else {
            throw ToolboxError.meetingNotFound
        }
        return detail
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
