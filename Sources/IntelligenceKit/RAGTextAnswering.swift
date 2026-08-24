import Foundation
import PortavozCore

/// Shared grounded-answer port for every explicitly selected local text
/// engine. Implementations receive the exact same bounded prompt contract;
/// provider choice cannot silently change evidence or grounding rules.
public protocol RAGTextAnswering: Sendable {
    func answer(
        question: String,
        passages: [RAGPassage]
    ) async throws -> String

    func streamAnswer(
        question: String,
        passages: [RAGPassage],
        onSnapshot: @escaping @Sendable (String) async -> Void
    ) async throws -> String
}

public extension RAGTextAnswering {
    /// Providers without a streaming transport still participate in the
    /// progressive application contract with one cumulative final snapshot.
    func streamAnswer(
        question: String,
        passages: [RAGPassage],
        onSnapshot: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let text = try await answer(question: question, passages: passages)
        try Task.checkCancellation()
        await onSnapshot(text)
        return text
    }
}

public enum RAGAnswerPromptError: Error, Equatable, Sendable {
    case emptyQuestion
    case noPassages
    case promptTooLarge(actualCharacters: Int, maximumCharacters: Int)
    case promptTooManyBytes(actualBytes: Int, maximumBytes: Int)
}

/// Provider-neutral prompt admission. The limit is an aggregate ceiling, not
/// per-passage truncation: all accepted evidence remains exact or generation
/// fails closed and the application continues to show the original citations.
public enum RAGAnswerPrompt {
    public static let maximumCharacters = 12_000
    public static let maximumUTF8Bytes = 48_000
    public static let maximumResponseTokens = 500

    public static let instructions = """
        You answer questions about the user's own meetings using ONLY the numbered context passages.
        \(PromptFactory.sourceMaterialGuard())
        Write a direct answer of one to three full sentences — never output a bare citation.
        After each claim, add the marker of the passage that supports it, e.g. "… media hora de latencia [2]."
        If the context does not contain the answer, say so plainly — never guess.
        """

    public struct Value: Equatable, Sendable {
        public let system: String
        public let user: String

        public var characterCount: Int { system.count + user.count }
        public var utf8Count: Int { system.utf8.count + user.utf8.count }
    }

    public static func make(
        question rawQuestion: String,
        passages: [RAGPassage]
    ) throws -> Value {
        let question = rawQuestion.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw RAGAnswerPromptError.emptyQuestion }
        guard !passages.isEmpty else { throw RAGAnswerPromptError.noPassages }

        var user = ""
        func appendAdmitted(_ component: String) throws {
            let prospectiveCharacters = instructions.count
                + user.count
                + component.count
            guard prospectiveCharacters <= maximumCharacters else {
                throw RAGAnswerPromptError.promptTooLarge(
                    actualCharacters: prospectiveCharacters,
                    maximumCharacters: maximumCharacters)
            }
            let prospectiveBytes = instructions.utf8.count
                + user.utf8.count
                + component.utf8.count
            guard prospectiveBytes <= maximumUTF8Bytes else {
                throw RAGAnswerPromptError.promptTooManyBytes(
                    actualBytes: prospectiveBytes,
                    maximumBytes: maximumUTF8Bytes)
            }
            user.append(contentsOf: component)
        }

        try appendAdmitted("Context:\n")
        for (index, passage) in passages.enumerated() {
            if index > 0 { try appendAdmitted("\n") }
            try appendAdmitted("[\(index + 1)] (")
            try appendAdmitted(passage.meetingTitle)
            try appendAdmitted(", \(timestamp(passage.timestamp))) ")
            try appendAdmitted(passage.text)
        }
        try appendAdmitted("\n\nQuestion: ")
        try appendAdmitted(question)
        try appendAdmitted(
            "\n\nAnswer with full sentences, in the same language as the question.")
        return Value(system: instructions, user: user)
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// OpenAI-compatible grounded answerer used only with the fixed loopback
/// Ollama endpoint. The gateway independently rejects remote destinations.
public struct OpenAICompatibleRAGAnswerer: RAGTextAnswering {
    private let client: OpenAICompatibleRAGClient

    public init(
        endpoint: URL,
        model: String,
        apiKey: String,
        gateway: any DataEgressGateway,
        consentSource: DataEgressConsentSource = .summaryEngineSettings
    ) {
        client = OpenAICompatibleRAGClient(
            endpoint: endpoint,
            model: model,
            apiKey: apiKey,
            gateway: gateway,
            consentSource: consentSource)
    }

    public func answer(
        question: String,
        passages: [RAGPassage]
    ) async throws -> String {
        let prompt = try RAGAnswerPrompt.make(
            question: question,
            passages: passages)
        return try await client.complete(
            system: prompt.system,
            user: prompt.user)
    }
}

public struct OpenAICompatibleRAGClient: Sendable {
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
        consentSource: DataEgressConsentSource = .summaryEngineSettings
    ) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.gateway = gateway
        self.consentSource = consentSource
    }

    public func complete(system: String, user: String) async throws -> String {
        let request = try OpenAICompatibleChatCodec.urlRequest(
            endpoint: endpoint,
            model: model,
            apiKey: apiKey,
            system: system,
            user: user,
            temperature: 0.0,
            maxTokens: RAGAnswerPrompt.maximumResponseTokens)
        let destination = DataEgressDestination(
            url: endpoint.appendingPathComponent("chat/completions"))
        let metadata = DataEgressRequest(
            operation: .askAnswerGeneration,
            destination: destination,
            dataClassification: .meetingAnswerMaterial,
            meetingID: nil,
            consentSource: consentSource,
            providerDisclosure: DataEgressProviderDisclosure(
                providerID: endpoint.host ?? "Ollama",
                modelID: model))
        let response = try await gateway.perform(request, metadata: metadata)
        return try OpenAICompatibleChatCodec.responseContent(
            data: response.data,
            statusCode: response.statusCode)
    }
}

/// Grounded answers through the same injected process-owned MLX runtime used
/// by summaries. This value never constructs, caches, or downloads a model.
public struct MLXRAGAnswerer: RAGTextAnswering {
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

    public func answer(
        question: String,
        passages: [RAGPassage]
    ) async throws -> String {
        let prompt = try RAGAnswerPrompt.make(
            question: question,
            passages: passages)
        return try await IntelligenceScheduler.mlx.run(priority) {
            try await runtime.respond(
                system: prompt.system,
                user: prompt.user,
                directory: modelDirectory)
        }
    }
}
