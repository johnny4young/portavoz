import DiarizationKit
import Foundation
import IntelligenceKit
import ModelStoreKit
import PortavozCore
import StorageKit
import TranscriptionKit

/// `portavoz-cli summarize --file <wav> [--out-language es] [--glossary a,b,c]
///                         [--language en] [--recipe general] [--models-dir <dir>]
///                         [--byok <endpoint> --byok-model <model>]`
///
/// The whole M4 pipeline: transcribe → diarize → attribute → structured
/// summary. Default provider is Apple Foundation Models (on-device, D8);
/// `--byok` opts into an OpenAI-compatible cloud endpoint, key read from
/// the PORTAVOZ_BYOK_API_KEY environment variable.
enum SummarizeCommand {
    static func run(_ arguments: [String]) async {
        var file: String?
        var outLanguage = "en"
        var glossary: [String] = []
        var language: String?
        var modelsDir: String?
        var byokEndpoint: String?
        var byokModel = "gpt-4o-mini"
        var save = false
        var dbPath: String?

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--file":
                index += 1
                if index < arguments.count { file = arguments[index] }
            case "--out-language":
                index += 1
                if index < arguments.count { outLanguage = arguments[index] }
            case "--glossary":
                index += 1
                if index < arguments.count {
                    glossary = arguments[index].split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                }
            case "--language":
                index += 1
                if index < arguments.count { language = arguments[index] }
            case "--models-dir":
                index += 1
                if index < arguments.count { modelsDir = arguments[index] }
            case "--byok":
                index += 1
                if index < arguments.count { byokEndpoint = arguments[index] }
            case "--byok-model":
                index += 1
                if index < arguments.count { byokModel = arguments[index] }
            case "--save":
                save = true
            case "--db":
                index += 1
                if index < arguments.count { dbPath = arguments[index] }
            default:
                print("Unknown option: \(arguments[index])")
                return
            }
            index += 1
        }

        guard let file else {
            print(
                "Usage: portavoz-cli summarize --file <wav> [--out-language es] [--glossary a,b,c] [--byok <endpoint> --byok-model <model>]"
            )
            return
        }
        let url = URL(fileURLWithPath: file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("error: no such file: \(url.path)")
            return
        }

        // Resolve the provider before doing any heavy work.
        let provider: any SummaryProvider
        if let byokEndpoint {
            guard let endpoint = URL(string: byokEndpoint) else {
                print("error: invalid --byok endpoint")
                return
            }
            guard let key = ProcessInfo.processInfo.environment["PORTAVOZ_BYOK_API_KEY"] else {
                print("error: --byok requires the PORTAVOZ_BYOK_API_KEY environment variable")
                return
            }
            print("⚠️ BYOK: the transcript WILL be sent to \(endpoint.host ?? byokEndpoint) (model \(byokModel)).")
            provider = OpenAICompatibleSummaryProvider(
                endpoint: endpoint, model: byokModel, apiKey: key)
        } else if #available(macOS 26.0, *) {
            if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
                print("error: \(reason)")
                print("tip: use --byok <endpoint> --byok-model <model> as an explicit cloud fallback")
                return
            }
            provider = FoundationModelSummaryProvider()
        } else {
            print("error: on-device summaries need macOS 26+; use --byok as an explicit fallback")
            return
        }

        do {
            let store = CLISupport.modelStore(fromModelsDir: modelsDir)
            let engine = try await CLISupport.loadEngine(store: store)
            let diarizer = try await PyannoteDiarizer.loadRecommended(
                store: store, voiceprint: (try? VoiceprintStore().load()))

            print("Transcribing \(url.lastPathComponent)…")
            let meetingID = MeetingID()
            let hints = TranscriptionHints(language: language, meetingID: meetingID)
            let transcription = try await engine.transcribeFile(at: url, hints: hints)

            print("Diarizing…")
            let turns = try await diarizer.diarizeFile(at: url)
            let attribution = SpeakerAttributor.attribute(
                segments: transcription.segments, turns: turns, meetingID: meetingID)

            print("Summarizing (\(outLanguage))…")
            let request = SummaryRequest(
                meetingID: meetingID,
                segments: attribution.segments,
                speakers: attribution.speakers,
                recipe: .general,
                targetLanguage: outLanguage,
                glossary: glossary
            )
            let started = Date()
            let draft = try await provider.summarize(request)
            let elapsed = Date().timeIntervalSince(started)

            print("")
            print(draft.markdown)
            print("")
            let labelsByID = Dictionary(
                uniqueKeysWithValues: attribution.speakers.map { ($0.id, $0.label) })
            if !draft.actionItems.isEmpty {
                print("action items (\(draft.actionItems.count)):")
                for item in draft.actionItems {
                    let owner = item.ownerSpeakerID.flatMap { labelsByID[$0] } ?? "—"
                    print("  • \(item.text)  [\(owner)]")
                }
            }
            print(String(
                format: "summary generated in %.1fs (M4 target: < 30 s) — language %@, %d segment(s)",
                elapsed, draft.language, attribution.segments.count
            ))

            if save {
                let storeDB = try MeetingsCommand.openStore(dbPath: dbPath)
                let now = Date()
                let record = Meeting(
                    id: meetingID,
                    title: url.deletingPathExtension().lastPathComponent,
                    startedAt: now.addingTimeInterval(-transcription.audioDuration),
                    endedAt: now,
                    language: language
                )
                try await storeDB.save(record)
                try await storeDB.save(attribution.speakers)
                try await storeDB.save(attribution.segments)
                let version = try await storeDB.saveSummary(draft)
                print("saved meeting \(meetingID.rawValue.uuidString) (summary v\(version))")
                print("browse it with: portavoz-cli meetings show \(meetingID.rawValue.uuidString)")
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }
}
