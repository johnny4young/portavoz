import Foundation
import PortavozCore
import TranscriptionKit

/// `portavoz-cli transcribe --file <wav> [--language es] [--models-dir <dir>]`
/// Batch transcription through the same pipeline the app will use.
enum TranscribeCommand {
    static func run(_ arguments: [String]) async {
        var file: String?
        var language: String?
        var modelsDir: String?

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--file":
                index += 1
                if index < arguments.count { file = arguments[index] }
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
            let engine = try await CLISupport.loadEngine(store: store)
            let hints = TranscriptionHints(language: language)

            print("Transcribing \(url.lastPathComponent)…")
            let result = try await engine.transcribeFile(at: url, hints: hints)

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
