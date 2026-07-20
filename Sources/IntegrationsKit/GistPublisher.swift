import Foundation
import PortavozCore

/// Publishes a meeting export as a GitHub Gist — the one-click share of
/// the sharing ladder's L0 (D12). Publishing sends the transcript OFF the
/// device, so every entry point must be an explicit, labeled user action
/// (D8); gists are secret (unlisted) unless the caller says otherwise.
public struct GistPublisher: Sendable {
    private let token: String
    private let gateway: any DataEgressGateway

    public init(token: String, gateway: any DataEgressGateway) {
        self.token = token
        self.gateway = gateway
    }

    /// Returns the gist's public URL.
    public func publish(
        meetingID: MeetingID,
        markdown: String,
        filename: String,
        description: String,
        isPublic: Bool = false
    ) async throws -> URL {
        let request = try Self.request(
            markdown: markdown, filename: filename, description: description,
            isPublic: isPublic, token: token)
        let response = try await gateway.perform(
            request,
            metadata: DataEgressRequest(
                operation: .publishGitHubGist,
                destination: DataEgressDestination(url: request.url!),
                dataClassification: .meetingExportDocument,
                meetingID: meetingID,
                consentSource: .explicitGistPublish,
                providerDisclosure: DataEgressProviderDisclosure(
                    providerID: "api.github.com")))
        guard response.statusCode == 201 else {
            let body = String(data: response.data.prefix(200), encoding: .utf8) ?? ""
            throw PublishError.requestFailed(status: response.statusCode, body: body)
        }
        return try Self.parseResponse(response.data)
    }

    public enum PublishError: Error, LocalizedError {
        case requestFailed(status: Int, body: String)
        case malformedResponse

        public var errorDescription: String? {
            switch self {
            case .requestFailed(let status, let body):
                return "GitHub responded \(status): \(body)"
            case .malformedResponse:
                return "GitHub returned a response without html_url"
            }
        }
    }

    // MARK: - Pure pieces (tested offline)

    static func request(
        markdown: String, filename: String, description: String,
        isPublic: Bool, token: String
    ) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com/gists")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "description": description,
            "public": isPublic,
            "files": [filename: ["content": markdown]]
        ])
        return request
    }

    static func parseResponse(_ data: Data) throws -> URL {
        struct GistResponse: Decodable { let html_url: String }
        guard
            let parsed = try? JSONDecoder().decode(GistResponse.self, from: data),
            let url = URL(string: parsed.html_url)
        else {
            throw PublishError.malformedResponse
        }
        return url
    }
}
