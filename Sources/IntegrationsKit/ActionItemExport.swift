import Foundation
import IntelligenceKit
import PortavozCore

/// Where an action item or summary can be exported. GitHub/Linear/Jira
/// exporters, the Gist share path, and the local MCP server arrive in the
/// integrations milestone; App Intents expose "meeting ended" as a trigger
/// so users can wire Portavoz to anything via Shortcuts.
public enum ExportDestination: String, Codable, Sendable, CaseIterable {
    case markdown
    case gitHubIssue
    case linearIssue
    case jiraTicket
    case gist
}

public protocol ActionItemExporter: Sendable {
    var destination: ExportDestination { get }
    func export(_ items: [ActionItem], from meetingID: MeetingID) async throws
}
