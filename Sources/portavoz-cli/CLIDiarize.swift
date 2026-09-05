import ApplicationKit
import Foundation

/// `portavoz-cli diarize --file <wav> [--attribute] [--language es] [--models-dir <dir>]`
///
/// Prints who spoke when. With `--attribute`, also batch-transcribes the
/// file and prints the speaker-attributed transcript — the M3 "who said
/// what" pipeline end to end (file plays the role of the system channel).
enum DiarizeCommand {
    // CLI de desarrollo: el parser de flags es un switch inherentemente largo.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func run(
        _ arguments: [String],
        platform: CLIPlatformDependencies
    ) async {
        var file: String?
        var attribute = false
        var language: String?
        var modelsDir: String?
        var threshold = platform.defaultClusteringThreshold

        do {
            var index = 0
            while index < arguments.count {
                switch arguments[index] {
                case "--file":
                    file = try CLIOptionValue.string(
                        arguments, index: &index, option: "--file")
                case "--threshold":
                    threshold = try CLIOptionValue.finiteFloat(
                        arguments,
                        index: &index,
                        option: "--threshold",
                        expected: "a finite number greater than 0 and less than 1",
                        accepting: CLIOptionBounds.acceptsDiarizationThreshold)
                case "--attribute":
                    attribute = true
                case "--language":
                    language = try CLIOptionValue.string(
                        arguments, index: &index, option: "--language")
                case "--models-dir":
                    modelsDir = try CLIOptionValue.string(
                        arguments, index: &index, option: "--models-dir")
                default:
                    print("Unknown option: \(arguments[index])")
                    return
                }
                index += 1
            }
        } catch {
            print("error: \(error.localizedDescription)")
            return
        }

        guard let file else {
            print("Usage: portavoz-cli diarize --file <wav> [--attribute] [--language es] [--models-dir <dir>]")
            return
        }
        let url = URL(fileURLWithPath: file)

        do {
            let workflow = platform.diarizeAudio(modelsDirectory: modelsDir)
            let result = try await workflow.execute(.init(
                fileURL: url,
                clusteringThreshold: threshold,
                attributeTranscript: attribute,
                language: language
            ) { progress in
                Self.printProgress(progress)
            })

            let voices = Set(result.turns.map(\.voiceLabel)).sorted()
            print("")
            for turn in result.turns {
                let start = CLISupport.timestamp(turn.startTime)
                let end = CLISupport.timestamp(turn.endTime)
                // qualityScore is an unnormalized score, not a probability.
                let quality = turn.confidence.map { String(format: " (q %.2f)", $0) } ?? ""
                print("[\(start)–\(end)] \(turn.voiceLabel)\(quality)")
            }
            print("")
            print(String(format: "%d speaker(s): %@ · %d turns · processed in %.1fs",
                         voices.count, voices.joined(separator: ", "),
                         result.turns.count, result.elapsed))

            guard attribute else { return }
            let labelsByID = Dictionary(
                uniqueKeysWithValues: result.speakers.map { ($0.id, $0.label) })

            print("")
            for segment in result.segments {
                let label = segment.speakerID.flatMap { labelsByID[$0] } ?? "?"
                let start = CLISupport.timestamp(segment.startTime)
                print("[\(start)] \(label): \(segment.text)")
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }

    private static func printProgress(_ progress: AudioAnalysisProgress) {
        switch progress {
        case .downloadingModel(let name, let megabytes):
            print("Downloading \(name) (\(megabytes) MB, sha256-verified)…")
        case .downloadProgress(let percent, let path):
            print("\r  \(percent)% \(path)", terminator: percent == 100 ? "\n" : "")
            fflush(stdout)
        case .loadingTranscriptionModel:
            print("Loading models (first load compiles for the ANE; can take ~a minute)…")
        case .diarizing(let fileName):
            print("Diarizing \(fileName ?? "")…")
        case .transcribingForAttribution:
            print("\nTranscribing for attribution…")
        default:
            break
        }
    }
}
