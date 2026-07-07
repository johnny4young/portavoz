import AudioCaptureKit
import Foundation
import PortavozCore

/// Dev harness for M1: records the microphone — and, on macOS 14.4+, the
/// audio of given PIDs or the whole system — to per-channel WAV files.
///
///     portavoz-cli record [--seconds N] [--pid <pid> ...] [--system] [--out <dir>]
///
/// The first run prompts for microphone (and audio-recording) permission on
/// behalf of the terminal.
@main
struct PortavozCLI {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.first == "devices" {
            listDevices()
            return
        }

        guard arguments.first == "record" else {
            print(
                """
                Portavoz dev CLI

                Usage:
                  portavoz-cli devices
                  portavoz-cli record [--seconds N] [--mic <name-or-uid>] [--pid <pid> ...] [--system] [--out <dir>]

                Options:
                  --seconds N        Recording length (default 8)
                  --mic <name|uid>   Input device to use (default: system default; see `devices`)
                  --pid <pid>        Also capture the audio output of this process (repeatable, macOS 14.4+)
                  --system           Also capture all system audio (macOS 14.4+)
                  --out <dir>        Output directory (default: current directory)
                """
            )
            return
        }
        arguments.removeFirst()

        var seconds = 8
        var pids: [pid_t] = []
        var captureSystem = false
        var outputPath = FileManager.default.currentDirectoryPath
        var micIdentifier: String?

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--seconds":
                index += 1
                if index < arguments.count { seconds = Int(arguments[index]) ?? seconds }
            case "--mic":
                index += 1
                if index < arguments.count { micIdentifier = arguments[index] }
            case "--pid":
                index += 1
                if index < arguments.count, let pid = Int32(arguments[index]) { pids.append(pid) }
            case "--system":
                captureSystem = true
            case "--out":
                index += 1
                if index < arguments.count { outputPath = arguments[index] }
            default:
                print("Unknown option: \(arguments[index])")
                return
            }
            index += 1
        }

        var sources: [any AudioCaptureSource] = [MicrophoneSource(deviceIdentifier: micIdentifier)]
        #if os(macOS)
        if #available(macOS 14.4, *) {
            if !pids.isEmpty {
                sources.append(ProcessTapSource(processIDs: pids))
            } else if captureSystem {
                sources.append(ProcessTapSource())
            }
        } else if !pids.isEmpty || captureSystem {
            print("Process taps require macOS 14.4+; recording microphone only.")
        }
        #endif

        let outputDirectory = URL(fileURLWithPath: outputPath)
        let session = RecordingSession(outputDirectory: outputDirectory)

        do {
            try await session.start(sources: sources)
            let channels = sources.map { $0.channel.rawValue }.joined(separator: " + ")
            print("Recording \(channels) for \(seconds)s → \(outputDirectory.path)")
            try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            let summary = await session.stop()

            for channel in AudioChannel.allCases {
                guard let url = summary.files[channel] else { continue }
                let written = summary.secondsWritten[channel] ?? 0
                let peak = summary.peaks[channel] ?? 0
                print(String(
                    format: "  %@: %@ (%.2fs, peak %.1f%%)",
                    channel.rawValue, url.lastPathComponent, written, peak * 100
                ))
            }
            if let drift = summary.driftSeconds {
                print(String(format: "  drift: %.0f ms", drift * 1000))
            }
            for (channel, message) in summary.errors {
                print("  ⚠️ \(channel.rawValue) failed: \(message)")
            }
            if summary.files.isEmpty {
                print("  no audio captured — check microphone/audio permissions for your terminal")
            } else if let systemPeak = summary.peaks[.system], systemPeak == 0 {
                print(
                    """
                      ⚠️ system channel recorded PURE SILENCE.
                      macOS taps yield silence when the app lacks the system-audio permission.
                      Fix: System Settings → Privacy & Security → Screen & System Audio Recording
                      → enable your terminal app (Terminal/iTerm), then fully quit and reopen it.
                    """
                )
            }
        } catch {
            print("error: \(error)")
        }
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
