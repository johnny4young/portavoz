import Foundation
import ModelStoreKit
import PortavozCore
import TranscriptionKit

/// `portavoz-cli transcribe --file <wav> [--language es] [--models-dir <dir>]`
/// Batch transcription through the same pipeline the app will use.
enum TranscribeCommand {
    // CLI de desarrollo: el parser de flags es un switch inherentemente largo.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func run(_ arguments: [String]) async {
        var file: String?
        var language: String?
        var modelsDir: String?
        var engineName = "parakeet"
        var vocabulary: [String] = []

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--file":
                index += 1
                if index < arguments.count { file = arguments[index] }
            case "--engine":
                index += 1
                if index < arguments.count { engineName = arguments[index] }
            case "--vocab":
                index += 1
                if index < arguments.count {
                    vocabulary = VocabularyPrompt.parse(arguments[index])
                }
            case "--language":
                index += 1
                if index < arguments.count { language = arguments[index] }
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
            print("Usage: portavoz-cli transcribe --file <wav> [--language es] [--models-dir <dir>]")
            return
        }
        let url = URL(fileURLWithPath: file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("error: no such file: \(url.path)")
            return
        }

        do {
            let store = CLISupport.modelStore(fromModelsDir: modelsDir)
            let hints = TranscriptionHints(language: language, vocabulary: vocabulary)

            print("Transcribing \(url.lastPathComponent) (\(engineName))…")
            let result: FileTranscription
            switch engineName {
            case "parakeet":
                let engine = try await CLISupport.loadEngine(store: store)
                result = try await engine.transcribeFile(at: url, hints: hints)
            case "whisper":
                let descriptor = ModelCatalog.whisperLargeV3Turbo
                let report = await store.verify(descriptor)
                if !report.isComplete {
                    print("Downloading \(descriptor.displayName) (\(descriptor.totalSizeBytes / 1_000_000) MB, sha256-verified)…")
                }
                let engine = try await WhisperEngine.loadRecommended(store: store) { progress in
                    guard progress.totalBytes > 0 else { return }
                    print("\r  \(Int(progress.fraction * 100))% \(progress.currentPath)", terminator: "")
                    fflush(stdout)
                }
                result = try await engine.transcribeFile(at: url, hints: hints)
            default:
                print("error: unknown engine \(engineName) (parakeet|whisper)")
                return
            }

            print("")
            for segment in result.segments {
                let start = CLISupport.timestamp(segment.startTime)
                let end = CLISupport.timestamp(segment.endTime)
                print("[\(start)–\(end)] \(segment.text)")
            }
            print("")
            print(String(
                format: "audio %.1fs · processed in %.1fs · %.0fx real time",
                result.audioDuration, result.processingTime, result.speedFactor
            ))
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }
}
