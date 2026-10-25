import ApplicationKit
import Foundation
import IntelligenceKit
import ModelStoreKit
import PortavozCore

/// The engine choice sampled for one polish call.
struct AppDictationPolishSelection: Sendable {
    let engine: SummaryEngine
    let ollamaModel: String?
    let ollamaEndpoint: URL
    let foundationModelsCapability: FoundationModelsCapability
}

/// Reads the selected summary engine on every call and polishes only with it:
/// an engine that cannot run throws `DictationPolishUnavailable`, never falls through.
struct AppDictationPolishRouter: DictationTextPolishing {
    let selection: @MainActor @Sendable () -> AppDictationPolishSelection?
    let mlxModelDirectory: @Sendable () async -> URL?
    let makeApple: @MainActor @Sendable () -> (any DictationTextPolishing)?
    let makeOllama: @Sendable (_ endpoint: URL, _ model: String) -> any DictationTextPolishing
    let makeMLX: @MainActor @Sendable (_ directory: URL) -> any DictationTextPolishing

    func polish(_ text: String) async throws -> String {
        guard let current = await selection() else {
            throw DictationPolishUnavailable(reason: L10n.text("Polish is unavailable right now."))
        }
        let polisher = try await resolve(current)
        do {
            return try await polisher.polish(text)
        } catch {
            throw Self.presented(error)
        }
    }

    private func resolve(_ current: AppDictationPolishSelection) async throws -> any DictationTextPolishing {
        switch current.engine {
        case .ollama:
            guard let model = current.ollamaModel else {
                throw DictationPolishUnavailable(reason: L10n.text(
                    "Choose an Ollama model in Intelligence Settings to polish dictations."))
            }
            guard DataEgressDestination(url: current.ollamaEndpoint).scope == .localDevice else {
                throw DictationPolishUnavailable(reason: L10n.text("Polish only uses Ollama on this Mac."))
            }
            return makeOllama(current.ollamaEndpoint, model)
        case .mlx:
            guard let directory = await mlxModelDirectory() else {
                throw DictationPolishUnavailable(reason: L10n.text(
                    "Download the built-in model in Intelligence Settings to polish dictations."))
            }
            return await makeMLX(directory)
        case .appleOnDevice:
            switch current.foundationModelsCapability {
            case .requiresMacOS26:
                throw DictationPolishUnavailable(reason: L10n.text(
                    "Polish needs Apple Intelligence on macOS 26."))
            case .unavailable(let reason):
                throw DictationPolishUnavailable(reason: L10n.format(
                    "Apple Intelligence is unavailable: %@.", reason))
            case .available:
                guard let apple = await makeApple() else {
                    throw DictationPolishUnavailable(reason: L10n.text(
                        "Polish needs Apple Intelligence on macOS 26."))
                }
                return apple
            }
        }
    }

    /// Admission refusals and an unreachable engine become a short reason;
    /// cancellation and generation failures pass through unchanged.
    static func presented(_ error: any Error) -> any Error {
        if error is DictationPolishUnavailable || error is CancellationError { return error }
        if let admission = error as? AppResourceGovernorAdmissionError {
            return DictationPolishUnavailable(reason: admission.errorDescription ?? L10n.text(
                "Polish is unavailable right now."))
        }
        if let runtime = error as? AppServices.MLXRuntimeError {
            switch runtime {
            case .modelInUse:
                return DictationPolishUnavailable(reason: L10n.text(
                    "The built-in model is busy. Try again in a moment."))
            case .servicesUnavailable:
                return DictationPolishUnavailable(reason: L10n.text("Polish is unavailable right now."))
            case .inconsistentResidency:
                return error
            }
        }
        if let url = error as? URLError, unreachableCodes.contains(url.code) {
            return DictationPolishUnavailable(reason: L10n.text(
                "Ollama is not responding on localhost:11434. Install it and run “ollama serve”."))
        }
        return error
    }

    private static let unreachableCodes: Set<URLError.Code> = [
        .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet
    ]
}

@MainActor
extension AppServices {
    /// Polishes one clean dictation with the summary engine selected at call time.
    var dictationPolisher: any DictationTextPolishing {
        AppDictationPolishRouter(
            selection: { [weak self] in self?.dictationPolishSelection },
            mlxModelDirectory: { [modelLifecycle] in
                await modelLifecycle.installation(for: ModelCatalog.mlxQwen35)?.directory
            },
            makeApple: {
                guard #available(macOS 26.0, *) else { return nil }
                return FoundationModelDictationPolisher()
            },
            makeOllama: { [dataEgressGateway] endpoint, model in
                OpenAICompatibleDictationPolisher(
                    endpoint: endpoint, model: model, apiKey: "ollama", gateway: dataEgressGateway)
            },
            makeMLX: { [weak self] directory in
                guard let self else { return AppUnavailableDictationPolisher() }
                return self.makeMLXDictationPolisher(modelDirectory: directory)
            })
    }

    private var dictationPolishSelection: AppDictationPolishSelection {
        AppDictationPolishSelection(
            engine: summaryEngine,
            ollamaModel: ollamaModel,
            ollamaEndpoint: OllamaService.openAIEndpoint,
            foundationModelsCapability: foundationModelsCapability)
    }
}

private struct AppUnavailableDictationPolisher: DictationTextPolishing {
    func polish(_ text: String) async throws -> String {
        throw DictationPolishUnavailable(reason: L10n.text("Polish is unavailable right now."))
    }
}
