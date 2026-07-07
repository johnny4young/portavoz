import Foundation
import PortavozCore
import TranscriptionKit

/// Hidden launch-arg bench mode (M12): SpeechAnalyzer refuses to run in an
/// unbundled CLI (the Speech daemon never answers — spike finding), so the
/// comparative benchmark runs INSIDE the app bundle and prints to stdout:
///
///   Portavoz.app/Contents/MacOS/portavoz-app --bench-live <file> \
///       [--seconds 60] [--language es] [--vocab "a,b"]
///
/// The process exits when the bench finishes — it never touches the UI,
/// the library or the database.
enum BenchMode {
    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--bench-live"),
            arguments.indices.contains(flag + 1)
        else { return }
        let file = arguments[flag + 1]

        func value(after option: String) -> String? {
            guard let index = arguments.firstIndex(of: option),
                arguments.indices.contains(index + 1)
            else { return nil }
            return arguments[index + 1]
        }
        let seconds = value(after: "--seconds").flatMap(Int.init) ?? 60
        let language = value(after: "--language")
        let vocabulary = value(after: "--vocab").map(VocabularyPrompt.parse) ?? []

        Task.detached {
            do {
                guard #available(macOS 26.0, *) else {
                    print("error: el bench de SpeechAnalyzer requiere macOS 26")
                    exit(1)
                }
                guard SpeechAnalyzerEngine.isAvailable else {
                    print("error: SpeechTranscriber no está disponible en este equipo")
                    exit(1)
                }
                let hints = TranscriptionHints(language: language, vocabulary: vocabulary)
                print("bench-live (in-app) · speech · \(seconds)s de \(file)")
                let locale = try await SpeechAnalyzerEngine.ensureAssets(
                    language: language) { print($0) }
                print("locale: \(locale.identifier)")
                let result = try await LiveTranscriptionBench.run(
                    file: URL(fileURLWithPath: file), seconds: seconds,
                    transcribe: {
                        SpeechAnalyzerEngine().transcribe($0, hints: hints, locale: locale)
                    },
                    log: { print($0) })
                print("")
                print(result.report)
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
    }
}
