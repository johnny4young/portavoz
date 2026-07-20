import ApplicationKit
import Foundation

/// `portavoz-cli summarize --file <wav> [--out-language es] [--glossary a,b,c]
///                         [--language en] [--recipe general] [--models-dir <dir>]
///                         [--byok <endpoint> --byok-model <model>]`
///
/// The whole M4 pipeline: transcribe → diarize → attribute → structured
/// summary. Default provider is Apple Foundation Models (on-device, D8);
/// `--byok` opts into an OpenAI-compatible cloud endpoint, key read from
/// the PORTAVOZ_BYOK_API_KEY environment variable.
enum SummarizeCommand {
    // CLI de desarrollo: el parser de flags es un switch inherentemente largo.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func run(
        _ arguments: [String],
        platform: CLIPlatformDependencies
    ) async {
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
                // One-line usage text.
                // swiftlint:disable:next line_length
                "Usage: portavoz-cli summarize --file <wav> [--out-language es] [--glossary a,b,c] [--byok <endpoint> --byok-model <model>]"
            )
            return
        }
        let url = URL(fileURLWithPath: file)
        let application: CLIComposition?
        do {
            application = save
                ? try CLIComposition.open(dbPath: dbPath, platform: platform)
                : nil
        } catch {
            print("error: \(error.localizedDescription)")
            return
        }

        // Resolve the provider before doing any heavy work.
        let provider: CLISummaryProviderConfiguration
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
            provider = .byok(endpoint: endpoint, model: byokModel, apiKey: key)
        } else {
            provider = .onDevice
        }

        do {
            let workflow = try application.map {
                try $0.summarizeAudio(
                    modelsDirectory: modelsDir,
                    provider: provider)
            } ?? platform.summarizeAudio(
                modelsDirectory: modelsDir,
                provider: provider,
                store: nil)
            let result = try await workflow.execute(.init(
                fileURL: url,
                spokenLanguage: language,
                outputLanguage: outLanguage,
                glossary: glossary
            ) { progress in
                Self.printProgress(progress)
            })

            print("")
            print(result.draft.markdown)
            print("")
            let labelsByID = Dictionary(
                uniqueKeysWithValues: result.attribution.speakers.map { ($0.id, $0.label) })
            if !result.draft.actionItems.isEmpty {
                print("action items (\(result.draft.actionItems.count)):")
                for item in result.draft.actionItems {
                    let owner = item.ownerSpeakerID.flatMap { labelsByID[$0] } ?? "—"
                    print("  • \(item.text)  [\(owner)]")
                }
            }
            print(String(
                format: "summary generated in %.1fs (M4 target: < 30 s) — language %@, %d segment(s)",
                result.elapsed, result.draft.language, result.attribution.segments.count
            ))

            if let version = result.savedVersion {
                print("saved meeting \(result.meetingID.rawValue.uuidString) (summary v\(version))")
                print("browse it with: portavoz-cli meetings show \(result.meetingID.rawValue.uuidString)")
            }
        } catch let error as CLISummaryProviderConfigurationError {
            print("error: \(error.localizedDescription)")
            if case .unavailable = error {
                print("tip: use --byok <endpoint> --byok-model <model> as an explicit cloud fallback")
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
        case .installedModel:
            break
        case .transcribing(let fileName, _):
            print("Transcribing \(fileName)…")
        case .diarizing:
            print("Diarizing…")
        case .summarizing(let language):
            print("Summarizing (\(language))…")
        case .transcribingForAttribution:
            break
        }
    }
}
