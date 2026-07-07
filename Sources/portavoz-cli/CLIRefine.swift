import DiarizationKit
import Foundation
import ModelStoreKit
import PortavozCore
import StorageKit
import TranscriptionKit

/// `portavoz-cli meetings refine <uuid> [--file <wav>] [--language es]
///                                [--db <path>] [--models-dir <dir>]`
///
/// The D7 quality re-pass: re-transcribes the meeting's audio with
/// Whisper large-v3-turbo, re-diarizes, re-attributes, and atomically
/// replaces the live transcript (old segments become tombstones).
/// Uses the stored audio directory, or `--file` for imported meetings.
enum RefineCommand {
    static func run(meetingRaw: String, _ arguments: [String]) async {
        var file: String?
        var language: String?
        var dbPath: String?
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
            case "--db":
                index += 1
                if index < arguments.count { dbPath = arguments[index] }
            case "--models-dir":
                index += 1
                if index < arguments.count { modelsDir = arguments[index] }
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
        let meetingID = MeetingID(rawValue: uuid)

        do {
            let store = try MeetingsCommand.openStore(dbPath: dbPath)
            guard let detail = try await store.detail(meetingID) else {
                print("error: no such meeting")
                return
            }

            // Resolve audio: --file plays the system channel for imported
            // meetings; recorded meetings use their stored directory.
            var systemFile: URL?
            var microphoneFile: URL?
            if let file {
                systemFile = URL(fileURLWithPath: file)
            } else if let relative = detail.meeting.audioDirectory {
                let base = MeetingStore.defaultDatabaseURL.deletingLastPathComponent()
                    .appendingPathComponent(relative)
                let system = base.appendingPathComponent("system.wav")
                let microphone = base.appendingPathComponent("microphone.wav")
                systemFile = FileManager.default.fileExists(atPath: system.path) ? system : nil
                microphoneFile =
                    FileManager.default.fileExists(atPath: microphone.path) ? microphone : nil
            }
            guard systemFile != nil || microphoneFile != nil else {
                print("error: la reunión no tiene audio guardado — usa --file <wav>")
                return
            }

            let modelStore = CLISupport.modelStore(fromModelsDir: modelsDir)
            let whisperModel = ModelCatalog.whisperLargeV3Turbo
            let report = await modelStore.verify(whisperModel)
            if !report.isComplete {
                print("Descargando \(whisperModel.displayName) (\(whisperModel.totalSizeBytes / 1_000_000) MB, sha256-verificado)…")
            }
            let whisper = try await WhisperEngine.loadRecommended(store: modelStore) { progress in
                guard progress.totalBytes > 0 else { return }
                print("\r  \(Int(progress.fraction * 100))% \(progress.currentPath)", terminator: "")
                fflush(stdout)
            }
            print("")

            let hints = TranscriptionHints(language: language, meetingID: meetingID)
            var segments: [TranscriptSegment] = []
            if let systemFile {
                print("Re-transcribiendo canal system con Whisper…")
                let result = try await whisper.transcribeFile(
                    at: systemFile, hints: hints, channel: .system)
                segments.append(contentsOf: result.segments)
                print(String(format: "  %.1fs de audio en %.1fs (%.0fx)",
                             result.audioDuration, result.processingTime, result.speedFactor))
            }
            if let microphoneFile {
                print("Re-transcribiendo canal microphone con Whisper…")
                let result = try await whisper.transcribeFile(
                    at: microphoneFile, hints: hints, channel: .microphone)
                segments.append(contentsOf: result.segments)
            }
            segments.sort { $0.startTime < $1.startTime }

            var turns: [SpeakerTurn] = []
            if let systemFile {
                print("Re-diarizando…")
                let diarizer = try await PyannoteDiarizer.loadRecommended(
                    store: modelStore, voiceprint: (try? VoiceprintStore().load()) ?? nil)
                turns = try await diarizer.diarizeFile(at: systemFile)
            }
            let attribution = SpeakerAttributor.attribute(
                segments: segments, turns: turns, meetingID: meetingID)

            try await store.replaceCast(
                for: meetingID,
                speakers: attribution.speakers,
                segments: attribution.segments)

            print("Transcript refinado ✓ — \(attribution.segments.count) segmentos, \(attribution.speakers.count) hablante(s).")
            print("Tip: regenera el resumen para que use el transcript nuevo.")
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }
}
