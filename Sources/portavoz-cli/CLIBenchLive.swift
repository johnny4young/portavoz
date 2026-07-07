import Foundation
import ModelStoreKit
import PortavozCore
import TranscriptionKit

/// `portavoz-cli bench-live --file <wav|caf> [--engine parakeet|speech]
///                          [--seconds N] [--language es] [--vocab "a,b"]
///                          [--models-dir <dir>]`
///
/// Thin CLI front for `LiveTranscriptionBench` (TranscriptionKit). NOTE:
/// `--engine speech` only works INSIDE the app bundle (Speech daemon won't
/// answer an unbundled process — spike finding); use
/// `Portavoz.app/Contents/MacOS/portavoz-app --bench-live …` for that.
enum BenchLiveCommand {
    static func run(_ arguments: [String]) async {
        var file: String?
        var engineName = "parakeet"
        var seconds = 60
        var language: String?
        var vocabulary: [String] = []
        var modelsDir: String?

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--file":
                index += 1
                if index < arguments.count { file = arguments[index] }
            case "--engine":
                index += 1
                if index < arguments.count { engineName = arguments[index] }
            case "--seconds":
                index += 1
                if index < arguments.count { seconds = Int(arguments[index]) ?? seconds }
            case "--language":
                index += 1
                if index < arguments.count { language = arguments[index] }
            case "--vocab":
                index += 1
                if index < arguments.count {
                    vocabulary = VocabularyPrompt.parse(arguments[index])
                }
            case "--models-dir":
                index += 1
                if index < arguments.count { modelsDir = arguments[index] }
            default:
                print("Unknown option: \(arguments[index])")
                return
            }
            index += 1
        }

        guard let file else {
            print(
                "Usage: portavoz-cli bench-live --file <wav|caf> [--engine parakeet|speech] [--seconds N] [--language es] [--vocab \"a,b\"]"
            )
            return
        }

        do {
            let hints = TranscriptionHints(language: language, vocabulary: vocabulary)
            print("bench-live · \(engineName) · \(seconds)s de \(file)")

            let result: LiveTranscriptionBench.Result
            switch engineName {
            case "parakeet":
                let store = CLISupport.modelStore(fromModelsDir: modelsDir)
                let engine = try await CLISupport.loadEngine(store: store)
                result = try await LiveTranscriptionBench.run(
                    file: URL(fileURLWithPath: file), seconds: seconds,
                    transcribe: { engine.transcribe($0, hints: hints) },
                    log: { print($0) })
            case "speech":
                guard #available(macOS 26.0, *) else {
                    print("error: --engine speech requiere macOS 26")
                    return
                }
                guard SpeechAnalyzerEngine.isAvailable else {
                    print("error: SpeechTranscriber no está disponible en este equipo")
                    return
                }
                let locale = try await SpeechAnalyzerEngine.ensureAssets(
                    language: language) { print($0) }
                print("locale: \(locale.identifier)")
                result = try await LiveTranscriptionBench.run(
                    file: URL(fileURLWithPath: file), seconds: seconds,
                    transcribe: {
                        SpeechAnalyzerEngine().transcribe($0, hints: hints, locale: locale)
                    },
                    log: { print($0) })
            default:
                print("error: engine desconocido \(engineName) (parakeet|speech)")
                return
            }

            print("")
            print(result.report)
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }
}
