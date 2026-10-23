import ApplicationKit
import Foundation
import IntegrationsKit
import PortavozCore

/// The agent-facing reads of the dictation history. The store checks consent
/// in the same read as the rows, on every call.
struct DictationAgentReader: Sendable {
    let page: @Sendable (DictationRecordFilter, Int, Int) async throws -> DictationAgentRead<DictationRecordPage>
    let record: @Sendable (DictationRecordID) async throws -> DictationAgentRead<DictationRecord?>

    static func local(store: any DictationAgentStore) -> Self {
        Self(
            page: { filter, offset, limit in
                try await ReadDictationsForAgents(store: store).execute(
                    .init(filter: filter, offset: offset, limit: limit))
            },
            record: { try await ReadDictationForAgents(store: store).execute($0) })
    }
}

/// Read-only dictation tools appended after the frozen meeting catalog. They
/// stay listed while access is off and then answer how to turn it on.
enum DictationToolbox {
    static let pageDefault = 20
    static let pageMaximum = 100
    static let searchDefault = 20
    static let searchMaximum = 50
    /// List and search show this much of each text; `get_dictation` returns all of it.
    static let previewLength = 280
    static let notAllowed = """
        Dictation history is not shared with agents. The user can turn on \
        "Let agents and Shortcuts read the history" in Portavoz Settings › Audio & dictation.
        """

    enum ToolboxError: Error, LocalizedError {
        case badDictationID

        var errorDescription: String? { "id must be a dictation UUID" }
    }

    // swiftlint:disable line_length
    static func tools(reader: DictationAgentReader) -> [MCPTool] {
        [
            MCPTool(
                name: "list_dictations",
                description: "The user's saved dictations, newest first, with where each went and whether it reached its app. Paginated; the header says how to continue.",
                inputSchema: """
                    {"type":"object","properties":{"offset":{"type":"integer","description":"Dictations to skip (default 0)"},"limit":{"type":"integer","description":"Max dictations to return (default 20, max 100)"}}}
                    """
            ) { data in
                let args = (try? JSONDecoder().decode(ListArguments.self, from: data)) ?? ListArguments()
                let limit = min(max(1, args.limit ?? pageDefault), pageMaximum)
                return render(try await reader.page(.all, args.offset ?? 0, limit))
            },

            MCPTool(
                name: "search_dictations",
                description: "Search the user's saved dictations by words (accents ignored, the last word may be partial), optionally only one application or only text that did not reach its app.",
                inputSchema: """
                    {"type":"object","properties":{"query":{"type":"string","description":"Words to search for"},"application":{"type":"string","description":"Only dictations sent to this application name"},"only_not_delivered":{"type":"boolean","description":"Only dictations that did not reach their app"},"offset":{"type":"integer","description":"Matches to skip (default 0)"},"limit":{"type":"integer","description":"Max matches to return (default 20, max 50)"}},"required":["query"]}
                    """
            ) { data in
                let args = try JSONDecoder().decode(SearchArguments.self, from: data)
                let filter = DictationRecordFilter(
                    query: args.query, applicationName: args.application,
                    onlyNotDelivered: args.onlyNotDelivered ?? false)
                let limit = min(max(1, args.limit ?? searchDefault), searchMaximum)
                return render(try await reader.page(filter, args.offset ?? 0, limit))
            },

            MCPTool(
                name: "get_dictation",
                description: "One saved dictation in full: its text, the words before Clean mode when the user kept them, and where it went.",
                inputSchema: """
                    {"type":"object","properties":{"id":{"type":"string","description":"Dictation UUID from list_dictations or search_dictations"}},"required":["id"]}
                    """
            ) { data in
                let args = try JSONDecoder().decode(GetArguments.self, from: data)
                guard let uuid = UUID(uuidString: args.id) else { throw ToolboxError.badDictationID }
                switch try await reader.record(DictationRecordID(rawValue: uuid)) {
                case .notAllowed:
                    return notAllowed
                case .allowed(nil):
                    return "portavoz-dictations/1 id=\(uuid.uuidString)\n\nNo such dictation."
                case .allowed(let record?):
                    return detail(record)
                }
            }
        ]
    }
    // swiftlint:enable line_length

    /// One content-free header, then one entry per dictation.
    static func render(_ read: DictationAgentRead<DictationRecordPage>) -> String {
        guard case .allowed(let page) = read else { return notAllowed }
        let shown = page.records.count
        let range = shown == 0 ? "none" : "\(page.offset + 1)-\(page.offset + shown)"
        let next = page.offset + shown < page.total ? "\(page.offset + shown)" : "none"
        let header = "portavoz-dictations/1 total=\(page.total) range=\(range) next_offset=\(next)"
        guard shown > 0 else {
            return header + "\n\n" + (page.total == 0 ? "No dictations match." : "Offset is past the end.")
        }
        return header + "\n\n" + page.records.map(entry).joined(separator: "\n\n")
    }

    static func entry(_ record: DictationRecord) -> String {
        let text = record.text.count > previewLength
            ? String(record.text.prefix(previewLength)) + "… (get_dictation for the full text)"
            : record.text
        return summaryLine(record) + "\n" + indented(text)
    }

    static func detail(_ record: DictationRecord) -> String {
        var parts = [
            "portavoz-dictations/1 id=\(record.id.rawValue.uuidString)",
            summaryLine(record) + " · \(Int(record.duration.rounded())) s",
            "Text:\n" + indented(record.text)
        ]
        if let original = record.originalText {
            parts.append("Before Clean mode:\n" + indented(original))
        }
        return parts.joined(separator: "\n\n")
    }

    private static func summaryLine(_ record: DictationRecord) -> String {
        let delivery = switch record.delivery {
        case .verified: "inserted"
        case .dispatched: "sent, not verified"
        case .notDelivered: "not delivered"
        }
        return [
            record.id.rawValue.uuidString,
            ISO8601DateFormatter().string(from: record.createdAt),
            record.applicationName ?? "unknown app",
            delivery,
            record.mode.rawValue
        ].joined(separator: " · ")
    }

    private static func indented(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n")
    }
}

private struct ListArguments: Decodable {
    var offset: Int?
    var limit: Int?
}

private struct SearchArguments: Decodable {
    var query: String
    var application: String?
    var onlyNotDelivered: Bool?
    var offset: Int?
    var limit: Int?

    enum CodingKeys: String, CodingKey {
        case query, application, offset, limit
        case onlyNotDelivered = "only_not_delivered"
    }
}

private struct GetArguments: Decodable {
    var id: String
}
