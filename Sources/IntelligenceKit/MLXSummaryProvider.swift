import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import PortavozCore
import Tokenizers

/// Embedded local summarizer (D25's last mile, D32): a 4-bit Qwen3.5-4B
/// running IN-PROCESS on the GPU via MLX — summaries on Macs with neither
/// Apple Intelligence nor Ollama, zero external installs. Reuses the exact
/// prompt/JSON contract of the OpenAI-compatible provider, so switching
/// engines never changes the summary's shape. Does NOT go through the
/// IntelligenceScheduler: that lane exists for ANE contention; MLX runs on
/// the GPU.
public struct MLXSummaryProvider: SummaryProvider {
    public static let providerID = "mlx/qwen3.5-4b-mlx-4bit"

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
/// time on the GPU. The weights (2.3 GB resident) stay loaded only while
/// summaries keep coming: after `idleRelease` without a request the
/// container is dropped and the next summary reloads it (a few seconds
/// against a generation that takes tens) — so a summary never leaves the
/// app holding gigabytes for the rest of the day.
actor MLXModelCache {
    static let shared = MLXModelCache()

    /// Long enough that "regenerate in the other language" reuses the hot
    /// container, short enough that the RAM comes back promptly.
    private static let idleRelease: Duration = .seconds(120)

    private var container: ModelContainer?
    private var directory: URL?
    /// Bumped per request; a scheduled release only fires if no newer
    /// request has arrived while it slept.
    private var generation = 0

    func respond(system: String, user: String, directory newDirectory: URL) async throws -> String {
        generation += 1
        defer { scheduleIdleRelease(after: generation) }
        let container = try await load(newDirectory)
        // `perform` gives isolated access to the model context inside the
        // library's own actor — the blessed pattern for strict concurrency.
        return try await container.perform { context in
            // Qwen3.5 reasons by default and its "Thinking Process:" prose
            // never reaches the JSON contract; the template switch turns it
            // off (harmless for models whose template ignores it).
            let input = try await context.processor.prepare(
                input: UserInput(
                    chat: [.system(system), .user(user)],
                    additionalContext: ["enable_thinking": false]))
            // maxTokens is pure runaway protection (a rambling model would
            // hold the GPU indefinitely): a refined 56-min meeting produced
            // a legitimate 34k-character Spanish summary, so the cap leaves
            // real generations room and still bounds the worst case.
            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(maxTokens: 16_384, temperature: 0),
                context: context)
            var text = ""
            for await item in stream {
                if case .chunk(let chunk) = item { text += chunk }
            }
            return text
        }
    }

    private func scheduleIdleRelease(after requestGeneration: Int) {
        Task {
            try? await Task.sleep(for: Self.idleRelease)
            guard requestGeneration == generation else { return }
            container = nil
            directory = nil
        }
    }

    private func load(_ newDirectory: URL) async throws -> ModelContainer {
        if let container, directory == newDirectory { return container }
        // Without a cache limit MLX keeps every freed GPU buffer around and
        // a long-prompt prefill balloons to tens of GB (observed: 31 GB on a
        // 40-min meeting until macOS suspended the process). 20 MB is the
        // value the mlx-swift-examples LLMEval app ships with.
        MLX.Memory.cacheLimit = 20 * 1024 * 1024
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: newDirectory, using: #huggingFaceTokenizerLoader())
        container = loaded
        directory = newDirectory
        return loaded
    }
}
