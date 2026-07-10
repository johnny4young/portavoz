import Foundation
import IntelligenceKit
import ModelStoreKit
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
                    print("error: SpeechTranscriber is not available on this device")
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

extension BenchMode {
    /// `portavoz-app --mlx-smoke` — loads the (already downloaded) embedded
    /// model and summarizes a tiny synthetic Spanish meeting, printing the
    /// timing and the markdown. In-app on purpose: SwiftPM CLI builds cannot
    /// compile the Metal shaders (mlx-swift README), so the metallib only
    /// exists in xcodebuild products — same reasoning as `--bench-live`.
    static func runMLXSmokeIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--mlx-smoke") else { return }
        Task.detached {
            do {
                let directory = try await ModelStore()
                    .ensureAvailable(ModelCatalog.mlxQwen3)
                let meetingID = MeetingID()
                let me = Speaker(meetingID: meetingID, label: "Me", isMe: true)
                let ana = Speaker(meetingID: meetingID, label: "S1", displayName: "Ana")
                let lines: [(Speaker, String)] = [
                    (me, "Revisemos el presupuesto de transcripción del trimestre."),
                    (ana, "El costo actual es de doscientos dólares al mes y podemos bajarlo."),
                    (me, "Decidido: migramos el pipeline a los modelos locales esta semana."),
                    (ana, "Yo me encargo de la migración y te aviso el viernes.")
                ]
                let segments = lines.enumerated().map { index, line in
                    TranscriptSegment(
                        meetingID: meetingID, speakerID: line.0.id, channel: .system,
                        text: line.1, startTime: TimeInterval(index * 8),
                        endTime: TimeInterval(index * 8 + 7), isFinal: true)
                }
                let request = SummaryRequest(
                    meetingID: meetingID, segments: segments, speakers: [me, ana],
                    recipe: .general, targetLanguage: "es", glossary: [])
                let start = Date()
                let draft = try await MLXSummaryProvider(modelDirectory: directory)
                    .summarize(request)
                let elapsed = Date().timeIntervalSince(start)
                print("MLX smoke OK in \(String(format: "%.1f", elapsed)) s")
                print(draft.markdown)
                print("action items: \(draft.actionItems.map(\.text))")
                exit(0)
            } catch {
                print("MLX smoke FAILED: \(error)")
                exit(1)
            }
        }
    }
}
