import ApplicationKit
import Foundation
import PortavozCore

/// `portavoz-cli meetings refine <uuid> [--file <wav>] [--language es]
///                                [--db <path>] [--models-dir <dir>]
///                                [--vocab "QVTL,Portavoz,..."]
///                                [--threshold 0.45]`
///
/// Runs the same durable quality re-pass used by the app. The command owns
/// argument parsing and terminal output; ApplicationKit owns the workflow.
enum RefineCommand {
    // CLI de desarrollo: el parser de flags es un switch inherentemente largo.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func run(
        meetingRaw: String,
        _ arguments: [String],
        platform: CLIPlatformDependencies
    ) async {
        var file: String?
        var language: String?
        var dbPath: String?
        var modelsDir: String?
        var vocabulary: [String] = []
        var clusteringThreshold: Float?

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--file":
                index += 1
                if index < arguments.count { file = arguments[index] }
            case "--language":
                index += 1
                if index < arguments.count { language = arguments[index] }
            case "--vocab":
                index += 1
                if index < arguments.count {
                    vocabulary = arguments[index]
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
            case "--db":
                index += 1
                if index < arguments.count { dbPath = arguments[index] }
            case "--models-dir":
                index += 1
                if index < arguments.count { modelsDir = arguments[index] }
            case "--threshold":
                index += 1
                guard index < arguments.count,
                      let value = Float(arguments[index]),
                      value > 0,
                      value < 1
                else {
                    print("error: --threshold expects a number in (0, 1), e.g. 0.45")
                    return
                }
                clusteringThreshold = value
            default:
                print("Unknown option: \(arguments[index])")
                return
            }
            index += 1
        }

        guard let uuid = UUID(uuidString: meetingRaw) else {
            print("Usage: portavoz-cli meetings refine <meeting-uuid> [--file <wav>] [--language es]")
            return
        }
        let requestedClusteringThreshold = clusteringThreshold

        do {
            let application = try CLIComposition.open(
                dbPath: dbPath,
                platform: platform)
            let threshold = requestedClusteringThreshold ?? platform.defaultClusteringThreshold
            let workflow = application.refineMeeting(
                modelsDirectory: modelsDir,
                language: language,
                vocabulary: vocabulary,
                clusteringThreshold: threshold).run
            let progressPrinter = RefineProgressPrinter(
                clusteringThreshold: requestedClusteringThreshold)
            let result = try await workflow.execute(.init(
                meetingID: MeetingID(rawValue: uuid),
                externalAudioURL: file.map { URL(fileURLWithPath: $0) },
                languagePolicy: language.map(TranscriptLanguagePolicy.init(persistedValue:))
            ) { progress in
                await progressPrinter.print(progress)
            })

            print(
                "Refined transcript ✓ — \(result.segmentCount) segments, "
                    + "\(result.speakerCount) speaker(s).")
            print("Tip: regenerate the summary so it uses the new transcript.")
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }

}

private actor RefineProgressPrinter {
    private let clusteringThreshold: Float?
    private var announcedDownload = false
    private var beganTranscription = false

    init(clusteringThreshold: Float?) {
        self.clusteringThreshold = clusteringThreshold
    }

    func print(_ progress: RefineMeetingProgress) {
        switch progress {
        case .preparingModels:
            break
        case .downloadingWhisper(let size, let percent, let path):
            if !announcedDownload {
                Swift.print(
                    "Descargando Whisper large-v3-turbo (CoreML) "
                        + "(\(size), sha256-verificado)…")
                announcedDownload = true
            }
            let suffix = path.map { " \($0)" } ?? ""
            Swift.print(
                "\r  \(percent)%\(suffix)",
                terminator: percent == 100 ? "\n" : "")
            fflush(stdout)
        case .transcribingParticipants:
            if !beganTranscription { Swift.print("") }
            beganTranscription = true
            Swift.print("Re-transcribiendo canal system con Whisper…")
        case .transcribingMicrophone:
            Swift.print("Re-transcribiendo canal microphone con Whisper…")
        case .transcribed(let channel, let audioDuration, let processingTime, let speedFactor):
            guard channel == .system else { return }
            Swift.print(String(
                format: "  %.1fs de audio en %.1fs (%.0fx)",
                audioDuration,
                processingTime,
                speedFactor))
        case .identifyingSpeakers:
            if let clusteringThreshold {
                Swift.print("Re-diarizando (threshold \(clusteringThreshold))…")
            } else {
                Swift.print("Re-diarizando…")
            }
        }
    }
}
