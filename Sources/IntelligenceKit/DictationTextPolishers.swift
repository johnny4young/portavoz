import Foundation
import PortavozCore

/// Ollama's OpenAI-compatible endpoint, reached only through the egress
/// gateway, which refuses any destination that is not loopback.
public struct OpenAICompatibleDictationPolisher: DictationTextPolishing {
    public let endpoint: URL
    public let model: String
    private let apiKey: String
    private let gateway: any DataEgressGateway

    public init(endpoint: URL, model: String, apiKey: String, gateway: any DataEgressGateway) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.gateway = gateway
    }

    public func polish(_ text: String, recipe: String?) async throws -> String {
        let prompt = try DictationPolishPrompt.make(text, recipe: recipe)
        let request = try OpenAICompatibleChatCodec.urlRequest(
            endpoint: endpoint,
            model: model,
            apiKey: apiKey,
            system: prompt.system,
            user: prompt.user,
            temperature: 0.0,
            maxTokens: prompt.maximumResponseTokens)
        let metadata = DataEgressRequest(
            operation: .dictationPolish,
            destination: DataEgressDestination(url: endpoint.appendingPathComponent("chat/completions")),
            dataClassification: .dictationText,
            meetingID: nil,
            consentSource: .dictationPolishMode,
            providerDisclosure: DataEgressProviderDisclosure(
                providerID: endpoint.host ?? "Ollama",
                modelID: model))
        let response = try await gateway.perform(request, metadata: metadata)
        let content = try OpenAICompatibleChatCodec.responseContent(
            data: response.data,
            statusCode: response.statusCode)
        return DictationPolishPrompt.normalize(content, source: text)
    }
}

/// The process-owned MLX runtime, injected by composition; this value never
/// loads or downloads a model by itself.
public struct MLXDictationPolisher: DictationTextPolishing {
    private let modelDirectory: URL
    private let priority: IntelligenceScheduler.Priority
    private let runtime: any MLXSummaryRuntimeClient

    public init(
        modelDirectory: URL,
        priority: IntelligenceScheduler.Priority = .interactive,
        runtime: any MLXSummaryRuntimeClient
    ) {
        self.modelDirectory = modelDirectory
        self.priority = priority
        self.runtime = runtime
    }

    public func polish(_ text: String, recipe: String?) async throws -> String {
        let prompt = try DictationPolishPrompt.make(text, recipe: recipe)
        let content = try await IntelligenceScheduler.mlx.run(priority) {
            try await runtime.respond(
                system: prompt.system,
                user: prompt.user,
                directory: modelDirectory,
                maximumResponseTokens: prompt.maximumResponseTokens)
        }
        return DictationPolishPrompt.normalize(content, source: text)
    }
}

public extension OllamaService {
    /// Pinned to the same fixed loopback service as summaries and Ask.
    static func dictationPolisher(
        model: String,
        gateway: any DataEgressGateway
    ) -> OpenAICompatibleDictationPolisher {
        OpenAICompatibleDictationPolisher(
            endpoint: openAIEndpoint,
            model: model,
            apiKey: "ollama",
            gateway: gateway)
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// Apple's on-device model through the shared interactive scheduler.
@available(macOS 26.0, iOS 26.0, *)
public struct FoundationModelDictationPolisher: DictationTextPolishing {
    private let unavailabilityReason: @Sendable () -> String?

    public init(
        unavailabilityReason: @escaping @Sendable () -> String? = {
            FoundationModelSummaryProvider.unavailabilityReason()
        }
    ) {
        self.unavailabilityReason = unavailabilityReason
    }

    public func polish(_ text: String, recipe: String?) async throws -> String {
        if let reason = unavailabilityReason() {
            throw DictationPolishUnavailable(reason: reason)
        }
        let prompt = try DictationPolishPrompt.make(text, recipe: recipe)
        let session = LanguageModelSession(instructions: prompt.system)
        let content = try await IntelligenceScheduler.shared.run(.interactive) {
            try await session.respond(
                to: prompt.user,
                options: .greedy(maximumResponseTokens: prompt.maximumResponseTokens)
            ).content
        }
        return DictationPolishPrompt.normalize(content, source: text)
    }
}
#endif
