import AudioCaptureKit
import Foundation
import PortavozCore
import TranscriptionKit

/// `portavoz-cli record [--seconds N] [--mic <name-or-uid>] [--pid <pid> ...]
///                      [--system] [--out <dir>] [--transcribe] [--language es]
///                      [--models-dir <dir>] [--no-aec]`
///
/// With `--transcribe`, every captured channel gets its own live Parakeet
/// job fed from the recording pipeline; segments print as they stream.
enum RecordCommand {
    // CLI de desarrollo: el parser de flags es un switch inherentemente largo.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func run(_ arguments: [String]) async {
        var seconds = 8
        var pids: [pid_t] = []
        var captureSystem = false
        var outputPath = FileManager.default.currentDirectoryPath
        var micIdentifier: String?
        var transcribe = false
        var language: String?
        var modelsDir: String?
        var voiceProcessing = true

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
            case "--transcribe":
                transcribe = true
            case "--language":
                index += 1
                if index < arguments.count { language = arguments[index] }
            case "--models-dir":
                index += 1
                if index < arguments.count { modelsDir = arguments[index] }
            case "--no-aec":
                voiceProcessing = false
            default:
                print("Unknown option: \(arguments[index])")
                return
            }
            index += 1
        }

        var sources: [any AudioCaptureSource] = [
            MicrophoneSource(deviceIdentifier: micIdentifier, voiceProcessing: voiceProcessing)
        ]
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

        // Live transcription plumbing: one AsyncStream + engine job per
        // captured channel, fed from the recording chunk tap.
        var engine: ParakeetEngine?
        if transcribe {
            do {
                let store = CLISupport.modelStore(fromModelsDir: modelsDir)
                engine = try await CLISupport.loadEngine(store: store)
            } catch {
                print("error loading transcription model: \(error.localizedDescription)")
                return
            }
        }

        var feeds: [AudioChannel: AsyncStream<AudioChunk>.Continuation] = [:]
        var liveJobs: [Task<Int, Never>] = []
        if let engine {
            let meetingID = MeetingID()
            for source in sources {
                let channel = source.channel
                let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
                feeds[channel] = continuation
                let hints = TranscriptionHints(language: language, meetingID: meetingID)
                let segments = engine.transcribe(stream, hints: hints)
                liveJobs.append(Task {
                    var count = 0
                    do {
                        for try await segment in segments {
                            count += 1
                            let mark = segment.isFinal ? "✓" : "…"
                            let start = CLISupport.timestamp(segment.startTime)
                            print("  [\(channel.rawValue) \(start)] \(mark) \(segment.text)")
                        }
                    } catch {
                        print("  ⚠️ live transcription (\(channel.rawValue)) failed: \(error)")
                    }
                    return count
                })
            }
        }
        let channelFeeds = feeds

        let outputDirectory = URL(fileURLWithPath: outputPath)
        let session = RecordingSession(outputDirectory: outputDirectory)

        do {
            try await session.start(sources: sources) { chunk in
                channelFeeds[chunk.channel]?.yield(chunk)
            }
            let channels = sources.map { $0.channel.rawValue }.joined(separator: " + ")
            let suffix = transcribe ? " (live transcript below)" : ""
            print("Recording \(channels) for \(seconds)s → \(outputDirectory.path)\(suffix)")
            try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            let summary = await session.stop()

            for continuation in channelFeeds.values { continuation.finish() }
            var totalSegments = 0
            for job in liveJobs { totalSegments += await job.value }

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
            if transcribe {
                print("  live segments: \(totalSegments)")
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
}
