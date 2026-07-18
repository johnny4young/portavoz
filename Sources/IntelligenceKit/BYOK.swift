import Foundation
import PortavozCore

/// Pure OpenAI-compatible `/chat/completions` request/response codec shared by
/// gateway-backed capability clients. It deliberately owns no transport.
enum OpenAICompatibleChatCodec {
    // MARK: - Request/response shapes (static + pure for tests)

    // Firma interna estable que refleja el cuerpo de chat/completions.
    // swiftlint:disable:next function_parameter_count
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

    // DTOs de la respuesta chat/completions, aplanados a nivel de tipo
    // (nesting ≤ 1). El anidamiento Decodable no necesita reflejar el JSON.
    private struct ChatResponse: Decodable {
        let choices: [Choice]
    }
    private struct Choice: Decodable {
        let message: Message
    }
    private struct Message: Decodable { let content: String }

    static func parseContent(_ data: Data) throws -> String {
        guard
            let content = try? JSONDecoder().decode(ChatResponse.self, from: data)
                .choices.first?.message.content
        else {
            throw IntelligenceError.providerFailed("response is not a chat completion")
        }
        return content
    }

    static func responseContent(data: Data, statusCode: Int) throws -> String {
        guard (200..<300).contains(statusCode) else {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw IntelligenceError.providerFailed("HTTP \(statusCode): \(body)")
        }
        return try parseContent(data)
    }
}

/// OpenAI-compatible summary adapter. It cannot perform transport without the
/// shared egress gateway, regardless of whether the endpoint is local Ollama
/// or a remote BYOK provider.
public struct OpenAICompatibleSummaryClient: Sendable {
    public let endpoint: URL
    public let model: String
    private let apiKey: String
    private let gateway: any DataEgressGateway
    private let consentSource: DataEgressConsentSource

    public init(
        endpoint: URL,
        model: String,
        apiKey: String,
        gateway: any DataEgressGateway,
        consentSource: DataEgressConsentSource = .explicitSummaryProvider
    ) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.gateway = gateway
        self.consentSource = consentSource
    }

    public var providerLabel: String { endpoint.host ?? "BYOK" }

    var destination: DataEgressDestination {
        DataEgressDestination(url: endpoint.appendingPathComponent("chat/completions"))
    }

    func completeSummary(
        system: String,
        user: String,
        meetingID: MeetingID
    ) async throws -> String {
        let networkRequest = try OpenAICompatibleChatCodec.urlRequest(
            endpoint: endpoint,
            model: model,
            apiKey: apiKey,
            system: system,
            user: user,
            temperature: 0.3,
            maxTokens: nil)
        let metadata = DataEgressRequest(
            operation: .summaryGeneration,
            destination: destination,
            dataClassification: .meetingSummaryMaterial,
            meetingID: meetingID,
            consentSource: consentSource,
            providerDisclosure: DataEgressProviderDisclosure(
                providerID: providerLabel,
                modelID: model))
        let response = try await gateway.perform(networkRequest, metadata: metadata)
        return try OpenAICompatibleChatCodec.responseContent(
            data: response.data,
            statusCode: response.statusCode)
    }
}

struct CompanionDataEgressContext: Sendable {
    let meetingID: MeetingID?
    let consentSource: DataEgressConsentSource
}

/// Companion's OpenAI-compatible adapter. Unlike the general summary client,
/// it cannot perform transport without the shared egress policy gateway.
public struct CompanionBYOKClient: Sendable {
    public let endpoint: URL
    public let model: String
    private let apiKey: String
    private let gateway: any DataEgressGateway

    public init(
        endpoint: URL,
        model: String,
        apiKey: String,
        gateway: any DataEgressGateway
    ) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.gateway = gateway
    }

    public var providerLabel: String { endpoint.host ?? "BYOK" }

    var destination: DataEgressDestination {
        DataEgressDestination(url: endpoint.appendingPathComponent("chat/completions"))
    }

    func completeCompanionQuestion(
        system: String,
        user: String,
        maxTokens: Int,
        context: CompanionDataEgressContext
    ) async throws -> String {
        let networkRequest = try OpenAICompatibleChatCodec.urlRequest(
            endpoint: endpoint,
            model: model,
            apiKey: apiKey,
            system: system,
            user: user,
            temperature: 0.3,
            maxTokens: maxTokens)
        let metadata = DataEgressRequest(
            operation: .companionKnowledgeAnswer,
            destination: destination,
            dataClassification: .meetingQuestionOnly,
            meetingID: context.meetingID,
            consentSource: context.consentSource,
            providerDisclosure: DataEgressProviderDisclosure(
                providerID: providerLabel,
                modelID: model))
        let response = try await gateway.perform(networkRequest, metadata: metadata)
        return try OpenAICompatibleChatCodec.responseContent(
            data: response.data,
            statusCode: response.statusCode)
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
        endpoint: String,
        model: String,
        apiKey: String?,
        gateway: any DataEgressGateway,
        consentSource: DataEgressConsentSource = .explicitSummaryProvider
    ) -> OpenAICompatibleSummaryClient? {
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        guard
            let apiKey, !apiKey.isEmpty, !trimmedModel.isEmpty,
            let url = endpointURL(from: endpoint)
        else { return nil }
        return OpenAICompatibleSummaryClient(
            endpoint: url,
            model: trimmedModel,
            apiKey: apiKey,
            gateway: gateway,
            consentSource: consentSource)
    }

    /// The companion's BYOK client — non-nil ONLY when the user configured
    /// endpoint+model+key AND flipped the companion opt-in (D26). Missing
    /// pieces degrade to on-device, never to an error.
    public static func companionClient(
        isEnabled: Bool,
        endpoint: String,
        model: String,
        apiKey: String?,
        gateway: any DataEgressGateway
    ) -> CompanionBYOKClient? {
        let model = model.trimmingCharacters(in: .whitespaces)
        guard isEnabled, let apiKey, !apiKey.isEmpty, !model.isEmpty,
              let endpoint = endpointURL(from: endpoint)
        else { return nil }
        return CompanionBYOKClient(
            endpoint: endpoint,
            model: model,
            apiKey: apiKey,
            gateway: gateway)
    }
}
