import Foundation
import PortavozCore

/// Action items → dev trackers (M8). Publishing sends meeting content
/// OFF the device, so every entry point is an explicit, labeled action
/// (D8); tokens live in the Keychain (`SecretStore`).
public enum IssueExporterError: Error, LocalizedError {
    case requestFailed(status: Int, body: String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .requestFailed(let status, let body):
            return "el tracker respondió \(status): \(body)"
        case .malformedResponse:
            return "respuesta sin URL de issue"
        }
    }
}

extension SecretStore {
    public static let linearTokenService = "app.portavoz.linear-token"
}

// MARK: - GitHub Issues

public struct GitHubIssuesExporter: Sendable {
    private let repository: String
    private let token: String
    private let session: URLSession

    /// - Parameter repository: `owner/name`.
    public init(repository: String, token: String, session: URLSession = .shared) {
        self.repository = repository
        self.token = token
        self.session = session
    }

    /// Creates one issue per action item; returns its URL.
    public func publish(
        _ item: ActionItem, meetingTitle: String, ownerName: String? = nil
    ) async throws -> URL {
        let request = try Self.request(
            item: item, meetingTitle: meetingTitle, ownerName: ownerName,
            repository: repository, token: token)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 201 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw IssueExporterError.requestFailed(
                status: status, body: String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return try Self.parseResponse(data)
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
        var lines = ["Action item de la reunión **\(meetingTitle)**."]
        if let ownerName {
            lines.append("Responsable acordado: \(ownerName).")
        }
        lines.append("_Creado por Portavoz._")
        return lines.joined(separator: "\n\n")
    }
}

// MARK: - Linear

public struct LinearExporter: Sendable {
    private let teamID: String
    private let token: String
    private let session: URLSession

    public init(teamID: String, token: String, session: URLSession = .shared) {
        self.teamID = teamID
        self.token = token
        self.session = session
    }

    public func publish(
        _ item: ActionItem, meetingTitle: String, ownerName: String? = nil
    ) async throws -> URL {
        let request = try Self.request(
            item: item, meetingTitle: meetingTitle, ownerName: ownerName,
            teamID: teamID, token: token)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw IssueExporterError.requestFailed(
                status: status, body: String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return try Self.parseResponse(data)
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

    static func parseResponse(_ data: Data) throws -> URL {
        struct GraphQLResponse: Decodable {
            struct DataBox: Decodable {
                struct IssueCreate: Decodable {
                    struct Issue: Decodable { let url: String }
                    let success: Bool
                    let issue: Issue?
                }
                let issueCreate: IssueCreate
            }
            let data: DataBox?
        }
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
