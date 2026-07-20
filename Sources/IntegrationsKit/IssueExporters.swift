import Foundation
import PortavozCore

/// Action items → dev trackers (M8). Publishing sends meeting content
/// OFF the device, so every entry point is an explicit, labeled action
/// (D8); callers inject tokens from the platform secret adapter.
public enum IssueExporterError: Error, LocalizedError {
    case requestFailed(status: Int, body: String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .requestFailed(let status, let body):
            return "the tracker responded \(status): \(body)"
        case .malformedResponse:
            return "respuesta sin URL de issue"
        }
    }
}

// MARK: - GitHub Issues

public struct GitHubIssuesExporter: Sendable {
    private let repository: String
    private let token: String
    private let gateway: any DataEgressGateway

    /// - Parameter repository: `owner/name`.
    public init(
        repository: String,
        token: String,
        gateway: any DataEgressGateway
    ) {
        self.repository = repository
        self.token = token
        self.gateway = gateway
    }

    /// Creates one issue per action item; returns its URL.
    public func publish(
        _ item: ActionItem,
        meetingID: MeetingID,
        meetingTitle: String,
        ownerName: String? = nil
    ) async throws -> URL {
        let request = try Self.request(
            item: item, meetingTitle: meetingTitle, ownerName: ownerName,
            repository: repository, token: token)
        let response = try await gateway.perform(
            request,
            metadata: DataEgressRequest(
                operation: .createGitHubIssue,
                destination: DataEgressDestination(url: request.url!),
                dataClassification: .meetingActionItem,
                meetingID: meetingID,
                consentSource: .explicitGitHubIssuePublish,
                providerDisclosure: DataEgressProviderDisclosure(
                    providerID: "api.github.com")))
        guard response.statusCode == 201 else {
            throw IssueExporterError.requestFailed(
                status: response.statusCode,
                body: String(data: response.data.prefix(200), encoding: .utf8) ?? "")
        }
        return try Self.parseResponse(response.data)
    }

    static func request(
        item: ActionItem, meetingTitle: String, ownerName: String?,
        repository: String, token: String
    ) throws -> URLRequest {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(repository)/issues")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "title": item.text,
            "body": Self.body(item: item, meetingTitle: meetingTitle, ownerName: ownerName)
        ])
        return request
    }

    static func parseResponse(_ data: Data) throws -> URL {
        struct IssueResponse: Decodable { let html_url: String }
        guard
            let parsed = try? JSONDecoder().decode(IssueResponse.self, from: data),
            let url = URL(string: parsed.html_url)
        else { throw IssueExporterError.malformedResponse }
        return url
    }

    static func body(item: ActionItem, meetingTitle: String, ownerName: String?) -> String {
        var lines = ["Meeting action item **\(meetingTitle)**."]
        if let ownerName {
            lines.append("Agreed owner: \(ownerName).")
        }
        lines.append("_Created by Portavoz._")
        return lines.joined(separator: "\n\n")
    }
}

// MARK: - Linear

public struct LinearExporter: Sendable {
    private let teamID: String
    private let token: String
    private let gateway: any DataEgressGateway

    public init(
        teamID: String,
        token: String,
        gateway: any DataEgressGateway
    ) {
        self.teamID = teamID
        self.token = token
        self.gateway = gateway
    }

    public func publish(
        _ item: ActionItem,
        meetingID: MeetingID,
        meetingTitle: String,
        ownerName: String? = nil
    ) async throws -> URL {
        let request = try Self.request(
            item: item, meetingTitle: meetingTitle, ownerName: ownerName,
            teamID: teamID, token: token)
        let response = try await gateway.perform(
            request,
            metadata: DataEgressRequest(
                operation: .createLinearIssue,
                destination: DataEgressDestination(url: request.url!),
                dataClassification: .meetingActionItem,
                meetingID: meetingID,
                consentSource: .explicitLinearIssuePublish,
                providerDisclosure: DataEgressProviderDisclosure(
                    providerID: "api.linear.app")))
        guard (200..<300).contains(response.statusCode) else {
            throw IssueExporterError.requestFailed(
                status: response.statusCode,
                body: String(data: response.data.prefix(200), encoding: .utf8) ?? "")
        }
        return try Self.parseResponse(response.data)
    }

    static func request(
        item: ActionItem, meetingTitle: String, ownerName: String?,
        teamID: String, token: String
    ) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        // Linear personal API keys go bare in Authorization (no Bearer).
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": """
                mutation IssueCreate($input: IssueCreateInput!) {
                  issueCreate(input: $input) { success issue { url } }
                }
                """,
            "variables": [
                "input": [
                    "teamId": teamID,
                    "title": item.text,
                    "description": GitHubIssuesExporter.body(
                        item: item, meetingTitle: meetingTitle, ownerName: ownerName)
                ]
            ]
        ])
        return request
    }

    // DTOs de la respuesta GraphQL, aplanados a nivel de tipo (nesting ≤ 1).
    // El anidamiento Decodable no necesita reflejar la forma del JSON: cada
    // struct solo declara sus propias claves.
    private struct GraphQLResponse: Decodable {
        let data: DataBox?
    }
    private struct DataBox: Decodable {
        let issueCreate: IssueCreate
    }
    private struct IssueCreate: Decodable {
        let success: Bool
        let issue: Issue?
    }
    private struct Issue: Decodable { let url: String }

    static func parseResponse(_ data: Data) throws -> URL {
        guard
            let parsed = try? JSONDecoder().decode(GraphQLResponse.self, from: data),
            let issueCreate = parsed.data?.issueCreate,
            issueCreate.success,
            let raw = issueCreate.issue?.url,
            let url = URL(string: raw)
        else { throw IssueExporterError.malformedResponse }
        return url
    }
}
