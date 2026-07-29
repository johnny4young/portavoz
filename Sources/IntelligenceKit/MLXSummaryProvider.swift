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
    private let priority: IntelligenceScheduler.Priority
    private let runtime: any MLXSummaryRuntimeClient

    /// - Parameter modelDirectory: a ModelStore-VERIFIED directory (D7) —
    ///   this type never downloads anything by itself.
    /// - Parameter priority: Interactive for user-awaited generation and
    ///   background for durable post-capture work.
    public init(
        modelDirectory: URL,
        priority: IntelligenceScheduler.Priority = .interactive,
        runtime: any MLXSummaryRuntimeClient
    ) {
        self.modelDirectory = modelDirectory
        self.priority = priority
        self.runtime = runtime
    }

    public func summarize(_ request: SummaryRequest) async throws -> SummaryDraft {
        let prompt = OpenAICompatibleSummaryProvider.prompt(for: request)
        let content = try await IntelligenceScheduler.mlx.run(priority) {
            try await runtime.respond(
                system: prompt.system,
                user: prompt.user,
                directory: modelDirectory)
        }
        var draft = try OpenAICompatibleSummaryProvider.parseStructured(content)
            .draft(for: request)
        draft.fingerprint = SummaryFingerprint.compute(
            request: request, providerID: Self.providerID)
        return draft
    }
}

/// Narrow runtime port injected by executable composition. A provider cannot
/// construct a hidden process cache or report residency by itself.
public protocol MLXSummaryRuntimeClient: Sendable {
    func respond(
        system: String,
        user: String,
        directory: URL
    ) async throws -> String
}

public enum MLXSummaryRuntimeError: Error, Equatable, Sendable {
    case notPrepared
}

/// Owns one loaded MLX container. The app composes one process instance and
/// surrounds `prepare`/`respondPrepared`/`release` with its residency ledger.
/// Isolated benchmark products can use the `MLXSummaryRuntimeClient`
/// convenience directly; that path preserves the existing two-minute idle
/// release without pretending to be application residency evidence.
public actor MLXSummaryRuntime: MLXSummaryRuntimeClient {
    public init() {}

    /// Long enough that "regenerate in the other language" reuses the hot
    /// container, short enough that the RAM comes back promptly.
    private static let idleRelease: Duration = .seconds(120)

    private var container: ModelContainer?
    private var directory: URL?
    private var standaloneIdleGeneration = 0

    public func respond(
        system: String,
        user: String,
        directory newDirectory: URL
    ) async throws -> String {
        standaloneIdleGeneration += 1
        let idleGeneration = standaloneIdleGeneration
        defer { scheduleStandaloneIdleRelease(after: idleGeneration) }
        try await prepare(newDirectory)
        return try await respondPrepared(
            system: system,
            user: user,
            directory: newDirectory)
    }

    /// Loads or reuses the exact verified directory without beginning
    /// generation. Application composition publishes residency only after
    /// this method returns successfully.
    public func prepare(_ newDirectory: URL) async throws {
        if container != nil, directory == newDirectory { return }
        // Without a cache limit MLX keeps every freed GPU buffer around and
        // a long-prompt prefill balloons to tens of GB (observed: 31 GB on a
        // 40-min meeting until macOS suspended the process). 20 MB is the
        // value the mlx-swift-examples LLMEval app ships with.
        MLX.Memory.cacheLimit = 20 * 1024 * 1024
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: newDirectory, using: #huggingFaceTokenizerLoader())
        container = loaded
        directory = newDirectory
    }

    /// Generates only through the exact container that composition acquired.
    public func respondPrepared(
        system: String,
        user: String,
        directory expectedDirectory: URL
    ) async throws -> String {
        guard let container, directory == expectedDirectory else {
            throw MLXSummaryRuntimeError.notPrepared
        }
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

    /// Drops resident weights but never removes verified model files.
    public func release() {
        standaloneIdleGeneration += 1
        container = nil
        directory = nil
    }

    private func scheduleStandaloneIdleRelease(after requestGeneration: Int) {
        Task {
            try? await Task.sleep(for: Self.idleRelease)
            guard requestGeneration == standaloneIdleGeneration else { return }
            release()
        }
    }
}
