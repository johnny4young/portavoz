import Foundation
import ModelStoreKit
import PortavozCore
import TranscriptionKit

/// `portavoz-cli bench-live --file <wav|caf> [--engine parakeet|speech]
///                          [--seconds N] [--language es] [--vocab "a,b"]
///                          [--models-dir <dir>] [--reference <txt>]
///                          [--output <json>]`
///
/// Thin CLI front for `LiveTranscriptionBench` (TranscriptionKit). NOTE:
/// `--engine speech` only works INSIDE the app bundle (Speech daemon won't
/// answer an unbundled process — spike finding); use
/// `Portavoz.app/Contents/MacOS/portavoz-app --bench-live …` for that.
/// `--reference` scores WER/CER against a plain-text transcript;
/// `--output` writes the whole run as JSON like the scale benches, so
/// engine comparisons leave a committed evidence artifact instead of prose.
enum BenchLiveCommand {
    // CLI de desarrollo: el parser de flags es un switch inherentemente largo.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func run(_ arguments: [String]) async {
        var file: String?
        var engineName = "parakeet"
        var seconds = 60
        var language: String?
        var vocabulary: [String] = []
        var modelsDir: String?
        var referencePath: String?
        var outputPath: String?

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
            case "--reference":
                index += 1
                if index < arguments.count { referencePath = arguments[index] }
            case "--output":
                index += 1
                if index < arguments.count { outputPath = arguments[index] }
            default:
                print("Unknown option: \(arguments[index])")
                return
            }
            index += 1
        }

        guard let file else {
            print(
                // One-line usage text.
                // swiftlint:disable:next line_length
                "Usage: portavoz-cli bench-live --file <wav|caf> [--engine parakeet|speech] [--seconds N] [--language es] [--vocab \"a,b\"] [--reference <txt>] [--output <json>]"
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
                    print("error: SpeechTranscriber is not available on this device")
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

            var accuracy: TranscriptionAccuracy.Report?
            if let referencePath {
                let reference = try String(
                    contentsOfFile: referencePath, encoding: .utf8)
                let report = TranscriptionAccuracy.report(
                    reference: reference, hypothesis: result.hypothesis)
                accuracy = report
                print(String(
                    format: "WER %.1f%% · CER %.1f%% · ref %d words · hyp %d words",
                    report.wordErrorRate * 100, report.characterErrorRate * 100,
                    report.referenceWords, report.hypothesisWords))
            }
            if let outputPath {
                try writeJSON(
                    to: outputPath,
                    run: RunContext(
                        engine: engineName, file: file,
                        seconds: seconds, language: language),
                    result: result,
                    accuracy: accuracy)
                print("json: \(outputPath)")
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }

    private struct RunContext {
        let engine: String
        let file: String
        let seconds: Int
        let language: String?
    }

    /// Same convention as the scale benches: one JSON artifact per run so
    /// docs/evidence can carry the comparison instead of prose tables.
    private static func writeJSON(
        to path: String,
        run: RunContext,
        result: LiveTranscriptionBench.Result,
        accuracy: TranscriptionAccuracy.Report?
    ) throws {
        var payload: [String: Any] = [
            "bench": "bench-live",
            "engine": run.engine,
            "file": (run.file as NSString).lastPathComponent,
            "seconds": run.seconds,
            "finals": result.finals,
            "volatiles": result.volatiles,
            "characters": result.characters,
            "lag_p50_s": result.percentile(0.5),
            "lag_p95_s": result.percentile(0.95),
            "lag_max_s": result.lags.last ?? 0
        ]
        if let language = run.language { payload["language"] = language }
        if let firstResultAt = result.firstResultAt {
            payload["first_result_s"] = firstResultAt
        }
        if let accuracy {
            payload["wer"] = accuracy.wordErrorRate
            payload["cer"] = accuracy.characterErrorRate
            payload["reference_words"] = accuracy.referenceWords
            payload["hypothesis_words"] = accuracy.hypothesisWords
        }
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }
}
