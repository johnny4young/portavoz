import DiarizationKit
import Foundation
import ModelStoreKit
import PortavozCore
import TranscriptionKit

/// `portavoz-cli diarize --file <wav> [--attribute] [--language es] [--models-dir <dir>]`
///
/// Prints who spoke when. With `--attribute`, also batch-transcribes the
/// file and prints the speaker-attributed transcript — the M3 "who said
/// what" pipeline end to end (file plays the role of the system channel).
enum DiarizeCommand {
    static func run(_ arguments: [String]) async {
        var file: String?
        var attribute = false
        var language: String?
        var modelsDir: String?
        var threshold = PyannoteDiarizer.defaultClusteringThreshold

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--file":
                index += 1
                if index < arguments.count { file = arguments[index] }
            case "--threshold":
                index += 1
                if index < arguments.count { threshold = Float(arguments[index]) ?? threshold }
            case "--attribute":
                attribute = true
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
            print("Usage: portavoz-cli diarize --file <wav> [--attribute] [--language es] [--models-dir <dir>]")
            return
        }
        let url = URL(fileURLWithPath: file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("error: no such file: \(url.path)")
            return
        }

        do {
            let store = CLISupport.modelStore(fromModelsDir: modelsDir)
            let descriptor = ModelCatalog.speakerDiarization
            let report = await store.verify(descriptor)
            if !report.isComplete {
                print("Downloading \(descriptor.displayName) (\(descriptor.totalSizeBytes / 1_000_000) MB, sha256-verified)…")
            }
            // Enrolled voiceprint (if any) marks the user's turns as "Me".
            let voiceprint = (try? VoiceprintStore().load())
            let diarizer = try await PyannoteDiarizer.loadRecommended(
                store: store, clusteringThreshold: threshold, voiceprint: voiceprint)

            print("Diarizing \(url.lastPathComponent)…")
            let started = Date()
            let turns = try await diarizer.diarizeFile(at: url)
            let elapsed = Date().timeIntervalSince(started)

            let voices = Set(turns.map(\.voiceLabel)).sorted()
            print("")
            for turn in turns {
                let start = CLISupport.timestamp(turn.startTime)
                let end = CLISupport.timestamp(turn.endTime)
                // qualityScore is an unnormalized score, not a probability.
                let quality = turn.confidence.map { String(format: " (q %.2f)", $0) } ?? ""
                print("[\(start)–\(end)] \(turn.voiceLabel)\(quality)")
            }
            print("")
            print(String(format: "%d speaker(s): %@ · %d turns · processed in %.1fs",
                         voices.count, voices.joined(separator: ", "), turns.count, elapsed))

            guard attribute else { return }

            print("\nTranscribing for attribution…")
            let engine = try await CLISupport.loadEngine(store: store)
            let meetingID = MeetingID()
            let hints = TranscriptionHints(language: language, meetingID: meetingID)
            let transcription = try await engine.transcribeFile(at: url, hints: hints)

            let attribution = SpeakerAttributor.attribute(
                segments: transcription.segments, turns: turns, meetingID: meetingID)
            let labelsByID = Dictionary(
                uniqueKeysWithValues: attribution.speakers.map { ($0.id, $0.label) })

            print("")
            for segment in attribution.segments {
                let label = segment.speakerID.flatMap { labelsByID[$0] } ?? "?"
                let start = CLISupport.timestamp(segment.startTime)
                print("[\(start)] \(label): \(segment.text)")
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }
}
