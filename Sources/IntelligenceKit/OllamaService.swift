import Foundation
import PortavozCore

/// First-class local models via Ollama (D25/M12) — the answer to GAPS #7
/// ("a Mac without Apple Intelligence can't summarize locally"). Ollama
/// exposes an OpenAI-compatible `/v1/chat/completions` that needs no API
/// key, so summaries run 100% on-device against whatever model the user
/// pulled. This wraps detection + model listing; the summary itself reuses
/// `OpenAICompatibleSummaryProvider`.
public enum OllamaService {
    public static let baseURL = URL(string: "http://localhost:11434")!
    /// The OpenAI-compatible endpoint the summary provider talks to.
    public static var openAIEndpoint: URL { baseURL.appendingPathComponent("v1") }

    public struct Model: Sendable, Identifiable, Equatable {
        public let name: String
        public let parameterSize: String
        public let bytes: Int64
        public var id: String { name }

        public init(name: String, parameterSize: String, bytes: Int64) {
            self.name = name
            self.parameterSize = parameterSize
            self.bytes = bytes
        }
    }

    /// True when the Ollama server answers on localhost.
    public static func isRunning(session: URLSession = .shared) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        request.timeoutInterval = 2.5
        guard
            let (_, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return false }
        return true
    }

    /// The models the user has pulled (empty when Ollama is down).
    public static func models(session: URLSession = .shared) async -> [Model] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        guard let (data, _) = try? await session.data(for: request) else { return [] }
        return parseModels(data)
    }

    // DTOs de `/api/tags`, aplanados a nivel de tipo (nesting ≤ 1).
    private struct Tags: Decodable {
        let models: [Entry]
    }
    private struct Entry: Decodable {
        let name: String
        let size: Int64?
        let details: Details?
    }
    private struct Details: Decodable { let parameter_size: String? }

    /// Pure parse of `/api/tags` (static so it's unit-tested offline).
    static func parseModels(_ data: Data) -> [Model] {
        guard let tags = try? JSONDecoder().decode(Tags.self, from: data) else { return [] }
        return tags.models.map {
            Model(
                name: $0.name,
                parameterSize: $0.details?.parameter_size ?? "",
                bytes: $0.size ?? 0)
        }
    }

    /// A summary provider backed by a local Ollama model. No key: Ollama
    /// ignores the bearer, and nothing leaves the machine (D8-clean).
    public static func summaryProvider(
        model: String,
        gateway: any DataEgressGateway,
        consentSource: DataEgressConsentSource = .explicitSummaryProvider
    ) -> OpenAICompatibleSummaryProvider {
        OpenAICompatibleSummaryProvider(
            endpoint: openAIEndpoint,
            model: model,
            apiKey: "ollama",
            gateway: gateway,
            consentSource: consentSource)
    }

    /// Stable identity used by both the summary material cache and durable
    /// operation fingerprints. It mirrors the provider's endpoint-host/model
    /// identity instead of inventing a second Ollama-specific key.
    public static func providerID(model: String) -> String {
        "\(openAIEndpoint.host ?? "localhost")/\(model)"
    }
}
