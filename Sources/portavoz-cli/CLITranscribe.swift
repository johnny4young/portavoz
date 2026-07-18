import ApplicationKit
import Foundation

/// `portavoz-cli transcribe --file <wav> [--language es] [--models-dir <dir>]`
/// Batch transcription through the same pipeline the app will use.
enum TranscribeCommand {
    // CLI de desarrollo: el parser de flags es un switch inherentemente largo.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func run(
        _ arguments: [String],
        platform: CLIPlatformDependencies
    ) async {
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
                    vocabulary = arguments[index]
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
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
        guard let engine = AudioAnalysisEngine(rawValue: engineName) else {
            print("error: unknown engine \(engineName) (parakeet|whisper)")
            return
        }
        let url = URL(fileURLWithPath: file)

        do {
            let workflow = platform.transcribeAudio(
                modelsDirectory: modelsDir)
            let result = try await workflow.execute(.init(
                fileURL: url,
                engine: engine,
                language: language,
                vocabulary: vocabulary
            ) { progress in
                Self.printProgress(progress)
            })

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

    private static func printProgress(_ progress: AudioAnalysisProgress) {
        switch progress {
        case .transcribing(let fileName, let engine):
            print("Transcribing \(fileName) (\(engine?.rawValue ?? "parakeet"))…")
        case .downloadingModel(let name, let megabytes):
            print("Downloading \(name) (\(megabytes) MB, sha256-verified)…")
        case .downloadProgress(let percent, let path):
            print("\r  \(percent)% \(path)", terminator: percent == 100 ? "\n" : "")
            fflush(stdout)
        case .loadingTranscriptionModel:
            print("Loading models (first load compiles for the ANE; can take ~a minute)…")
        default:
            break
        }
    }
}
