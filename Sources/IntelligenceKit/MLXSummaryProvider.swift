import Foundation
import MLXLLM
import MLXLMCommon
import PortavozCore

/// Embedded local summarizer (D25's last mile, D32): a 4-bit Qwen3-4B
/// running IN-PROCESS on the GPU via MLX — summaries on Macs with neither
/// Apple Intelligence nor Ollama, zero external installs. Reuses the exact
/// prompt/JSON contract of the OpenAI-compatible provider, so switching
/// engines never changes the summary's shape. Does NOT go through the
/// IntelligenceScheduler: that lane exists for ANE contention; MLX runs on
/// the GPU.
public struct MLXSummaryProvider: SummaryProvider {
    public static let providerID = "mlx/qwen3-4b-instruct-2507-4bit"

    private let modelDirectory: URL

    /// - Parameter modelDirectory: a ModelStore-VERIFIED directory (D7) —
    ///   this type never downloads anything by itself.
    public init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    public func summarize(_ request: SummaryRequest) async throws -> SummaryDraft {
        let prompt = OpenAICompatibleSummaryProvider.prompt(for: request)
        let content = try await MLXModelCache.shared.respond(
            system: prompt.system, user: prompt.user, directory: modelDirectory)
        var draft = try OpenAICompatibleSummaryProvider.parseStructured(content)
            .draft(for: request)
        draft.fingerprint = SummaryFingerprint.compute(
            request: request, providerID: Self.providerID)
        return draft
    }
}

/// Owns the loaded container and serializes generation: one summary at a
/// time on the GPU. Weights stay loaded until the app quits.
actor MLXModelCache {
    static let shared = MLXModelCache()

    private var container: ModelContainer?
    private var directory: URL?

    func respond(system: String, user: String, directory newDirectory: URL) async throws -> String {
        let container = try await load(newDirectory)
        // `perform` gives isolated access to the model context inside the
        // library's own actor — the blessed pattern for strict concurrency.
        return try await container.perform { context in
            let input = try await context.processor.prepare(
                input: UserInput(chat: [.system(system), .user(user)]))
            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(temperature: 0),
                context: context)
            var text = ""
            for await item in stream {
                if case .chunk(let chunk) = item { text += chunk }
            }
            return text
        }
    }

    private func load(_ newDirectory: URL) async throws -> ModelContainer {
        if let container, directory == newDirectory { return container }
        let loaded = try await LLMModelFactory.shared.loadContainer(
            configuration: ModelConfiguration(directory: newDirectory))
        container = loaded
        directory = newDirectory
        return loaded
    }
}
