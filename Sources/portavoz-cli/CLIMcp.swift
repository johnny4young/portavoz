import ApplicationKit
import Foundation
import IntegrationsKit
import IntelligenceKit
import PortavozCore
import StorageKit

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
    static func run(_ arguments: [String]) async {
        var dbPath: String?
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--db", index + 1 < arguments.count {
                dbPath = arguments[index + 1]
                index += 1
            }
            index += 1
        }

        let store: MeetingStore
        do {
            store = try MeetingsCommand.openStore(dbPath: dbPath)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return
        }

        let server = MCPServer(tools: MeetingToolbox.tools(store: store))
        while let line = readLine(strippingNewline: true) {
            if let response = await server.handleLine(line) {
                print(response)
                fflush(stdout)
            }
        }
    }
}

/// The StorageKit-backed MCP tools. Assembled here (not in
/// IntegrationsKit) so the protocol layer stays free of Kit-to-Kit
/// dependencies; the app can assemble the same toolbox later.
enum MeetingToolbox {
    // MCP tool catalog: one long literal array of definitions,
    // one per tool; splitting it would not improve clarity.
    // swiftlint:disable:next function_body_length
    static func tools(store: MeetingStore) -> [MCPTool] {
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
                let meetings = try await store.meetings().prefix(limit)
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
                    {"type":"object","properties":{"query":{"type":"string","description":"Words to search for"}},"required":["query"]}
                    """
            ) { data in
                struct Args: Decodable { var query: String }
                let args = try JSONDecoder().decode(Args.self, from: data)
                let hits = try await store.search(args.query)
                guard !hits.isEmpty else { return "No matches for: \(args.query)" }
                return hits.map {
                    "[\(timestamp($0.startTime))] \($0.meetingTitle) (\($0.meetingID.rawValue.uuidString)): \($0.snippet)"
                }.joined(separator: "\n")
            },

            MCPTool(
                name: "get_transcript",
                description: "Full speaker-attributed transcript of one meeting.",
                inputSchema: """
                    {"type":"object","properties":{"meeting_id":{"type":"string","description":"Meeting UUID"}},"required":["meeting_id"]}
                    """
            ) { data in
                let detail = try await detail(from: data, store: store)
                let transcript = TranscriptFormatter.format(
                    segments: detail.segments, speakers: detail.speakers)
                return transcript.isEmpty ? "The meeting has no transcript." : transcript
            },

            MCPTool(
                name: "get_summary",
                description: "Latest summary snapshot (markdown) of one meeting, including action items.",
                inputSchema: """
                    {"type":"object","properties":{"meeting_id":{"type":"string","description":"Meeting UUID"}},"required":["meeting_id"]}
                    """
            ) { data in
                let detail = try await detail(from: data, store: store)
                guard let (draft, version) = try await store.summary(detail.meeting.id) else {
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
                let result = try await AskMeetings.local(store: store).answer(
                    args.question,
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
                let items = try await store.openActionItems(limit: limit)
                guard !items.isEmpty else { return "No pending action items." }
                return items.map { "- \($0.item.text) (\($0.meetingTitle))" }.joined(separator: "\n")
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

    private static func detail(from data: Data, store: MeetingStore) async throws -> MeetingDetail {
        struct Args: Decodable { var meeting_id: String }
        guard
            let args = try? JSONDecoder().decode(Args.self, from: data),
            let uuid = UUID(uuidString: args.meeting_id)
        else { throw ToolboxError.badMeetingID }
        guard let detail = try await store.detail(MeetingID(rawValue: uuid)) else {
            throw ToolboxError.meetingNotFound
        }
        return detail
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
