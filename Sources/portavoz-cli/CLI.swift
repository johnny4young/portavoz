import AudioCaptureKit
import Foundation

/// Dev harness. M1: dual-channel recording. M2: transcription — live
/// (sliding-window Parakeet), batch files, verified model downloads, and
/// the live-vs-batch acceptance bench.
///
/// The first run prompts for microphone (and audio-recording) permission on
/// behalf of the terminal.
@main
struct PortavozCLI {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage()
            return
        }
        arguments.removeFirst()

        switch command {
        case "devices":
            listDevices()
        case "record":
            await RecordCommand.run(arguments)
        case "transcribe":
            await TranscribeCommand.run(arguments)
        case "diarize":
            await DiarizeCommand.run(arguments)
        case "summarize":
            await SummarizeCommand.run(arguments)
        case "meetings":
            await MeetingsCommand.run(arguments)
        case "export":
            await ExportCommand.run(arguments)
        case "secrets":
            SecretsCommand.run(arguments)
        case "voice":
            await VoiceCommand.run(arguments)
        case "der":
            await DerCommand.run(arguments)
        case "models":
            await ModelsCommand.run(arguments)
        case "bench-m2":
            await BenchCommand.run(arguments)
        default:
            printUsage()
        }
    }

    static func printUsage() {
        print(
            """
            Portavoz dev CLI

            Usage:
              portavoz-cli devices
              portavoz-cli record [--seconds N] [--mic <name-or-uid>] [--pid <pid> ...] [--system]
                                  [--out <dir>] [--transcribe] [--language es] [--models-dir <dir>]
              portavoz-cli transcribe --file <wav> [--language es] [--models-dir <dir>]
              portavoz-cli diarize --file <wav> [--attribute] [--language es] [--models-dir <dir>]
              portavoz-cli summarize --file <wav> [--out-language es] [--glossary a,b,c]
                                     [--byok <endpoint> --byok-model <model>] [--save] [--db <path>]
              portavoz-cli meetings <list|show <id>|search <query>> [--db <path>]
              portavoz-cli export --meeting <uuid> [--format md|pdf] [--out <path>] [--gist [--public]]
              portavoz-cli secrets <set-github-token <token>|clear-github-token>
              portavoz-cli voice <enroll --file <wav>|status|delete>
              portavoz-cli models <download|verify|path> [--models-dir <dir>]
              portavoz-cli bench-m2 --batch-file <wav> [--seconds N] [--mic <name>] [--language es]

            Options:
              --seconds N        Recording length (default 8; bench default 60)
              --mic <name|uid>   Input device to use (default: system default; see `devices`)
              --pid <pid>        Also capture the audio output of this process (repeatable, macOS 14.4+)
              --system           Also capture all system audio (macOS 14.4+)
              --out <dir>        Output directory (default: current directory)
              --transcribe       Live-transcribe every captured channel while recording
              --language <tag>   Language hint, e.g. "es" or "en" (default: auto-detect)
              --models-dir <dir> Model store root (default: ~/Library/Application Support/Portavoz/Models)
            """
        )
    }

    static func listDevices() {
        #if os(macOS)
        do {
            let devices = try AudioDeviceCatalog.inputDevices()
            if devices.isEmpty {
                print("No input devices found.")
                return
            }
            print("Input devices:")
            for device in devices {
                print("  \(device.name)  [uid: \(device.uid)]")
            }
        } catch {
            print("error: \(error)")
        }
        #else
        print("Device listing is only implemented on macOS for now.")
        #endif
    }
}
