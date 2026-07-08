import Foundation
import PortavozCore

extension SecretStore {
    /// The BYOK API key — Keychain only, like every other secret (D8).
    public static let byokAPIKeyService = "app.portavoz.byok-api-key"
}

/// Minimal client for any OpenAI-compatible `/chat/completions` endpoint
/// (OpenAI, Groq, OpenRouter, Ollama, LM Studio…): one system + one user
/// message in, the assistant's text out. It is the BYOK building block
/// shared by the summary provider and the companion — D8 applies to every
/// caller: using it is an explicit, visibly-labeled user choice, never a
/// silent default.
public struct OpenAICompatibleChatClient: Sendable {
    public let endpoint: URL
    public let model: String
    private let apiKey: String
    private let session: URLSession

    public init(endpoint: URL, model: String, apiKey: String, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    /// Who answered, for disclosure labels on cards and summaries. The
    /// host is the honest name: "api.openai.com" says cloud, "localhost"
    /// says it never left the machine.
    public var providerLabel: String { endpoint.host ?? "BYOK" }

    public func complete(
        system: String,
        user: String,
        temperature: Double = 0.3,
        maxTokens: Int? = nil
    ) async throws -> String {
        let request = try Self.urlRequest(
            endpoint: endpoint, model: model, apiKey: apiKey,
            system: system, user: user,
            temperature: temperature, maxTokens: maxTokens)
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw IntelligenceError.providerFailed("HTTP \(status): \(body)")
        }
        return try Self.parseContent(data)
    }

    // MARK: - Request/response shapes (static + pure for tests)

    static func urlRequest(
        endpoint: URL, model: String, apiKey: String,
        system: String, user: String,
        temperature: Double, maxTokens: Int?
    ) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        if let maxTokens { body["max_tokens"] = maxTokens }

        var urlRequest = URLRequest(url: endpoint.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    static func parseContent(_ data: Data) throws -> String {
        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        guard
            let content = try? JSONDecoder().decode(ChatResponse.self, from: data)
                .choices.first?.message.content
        else {
            throw IntelligenceError.providerFailed("response is not a chat completion")
        }
        return content
    }
}

/// Where the BYOK choice lives. Endpoint and model are plain preferences;
/// the API key is ONLY in the Keychain. Reading yields a ready client or
/// nil — callers never see half-configured state.
public enum BYOKSettings {
    public static let endpointKey = "byokEndpoint"
    public static let modelKey = "byokModel"
    public static let companionEnabledKey = "companionBYOKEnabled"

    /// A usable http(s) URL with a host, or nil. The UI uses this to gate
    /// the opt-in toggle; `client` uses it to refuse half-configured state.
    public static func endpointURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil
        else { return nil }
        return url
    }

    /// Assembles a client from raw pieces; nil when anything is missing.
    public static func client(
        endpoint: String, model: String, apiKey: String?
    ) -> OpenAICompatibleChatClient? {
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        guard
            let apiKey, !apiKey.isEmpty, !trimmedModel.isEmpty,
            let url = endpointURL(from: endpoint)
        else { return nil }
        return OpenAICompatibleChatClient(endpoint: url, model: trimmedModel, apiKey: apiKey)
    }

    /// The companion's BYOK client — non-nil ONLY when the user configured
    /// endpoint+model+key AND flipped the companion opt-in (D26). Missing
    /// pieces degrade to on-device, never to an error.
    public static func companionClient(
        defaults: UserDefaults = .standard
    ) -> OpenAICompatibleChatClient? {
        companionClient(
            defaults: defaults,
            apiKey: (try? SecretStore.get(service: SecretStore.byokAPIKeyService)))
    }

    static func companionClient(
        defaults: UserDefaults, apiKey: String?
    ) -> OpenAICompatibleChatClient? {
        guard defaults.bool(forKey: companionEnabledKey) else { return nil }
        return client(
            endpoint: defaults.string(forKey: endpointKey) ?? "",
            model: defaults.string(forKey: modelKey) ?? "",
            apiKey: apiKey)
    }
}
