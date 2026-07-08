import Foundation

/// Publishes a meeting export as a GitHub Gist — the one-click share of
/// the sharing ladder's L0 (D12). Publishing sends the transcript OFF the
/// device, so every entry point must be an explicit, labeled user action
/// (D8); gists are secret (unlisted) unless the caller says otherwise.
public struct GistPublisher: Sendable {
    private let token: String
    private let session: URLSession

    public init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    /// Returns the gist's public URL.
    public func publish(
        markdown: String,
        filename: String,
        description: String,
        isPublic: Bool = false
    ) async throws -> URL {
        let request = try Self.request(
            markdown: markdown, filename: filename, description: description,
            isPublic: isPublic, token: token)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 201 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw PublishError.requestFailed(status: status, body: body)
        }
        return try Self.parseResponse(data)
    }

    public enum PublishError: Error, LocalizedError {
        case requestFailed(status: Int, body: String)
        case malformedResponse

        public var errorDescription: String? {
            switch self {
            case .requestFailed(let status, let body):
                return "GitHub respondió \(status): \(body)"
            case .malformedResponse:
                return "GitHub devolvió una respuesta sin html_url"
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
