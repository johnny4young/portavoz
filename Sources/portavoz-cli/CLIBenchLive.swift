import AVFoundation
import Foundation
import ModelStoreKit
import PortavozCore
import TranscriptionKit

/// `portavoz-cli bench-live --file <wav|caf> [--engine parakeet|speech]
///                          [--seconds N] [--language es] [--vocab "a,b"]
///                          [--models-dir <dir>]`
///
/// The M12 decision harness: paces a recording through an engine in REAL
/// TIME (1 s chunks, 1 s sleeps — as if it were live capture) and measures
/// finalization lag per segment: wallclock_when_emitted − feed_start −
/// segment.endTime. Comparable across engines because both are driven by
/// the same feed.
enum BenchLiveCommand {
    /// Averages all channels into mono (the AudioCaptureKit helper is
    /// internal to that module).
    private static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return [] }
        let channels = Int(buffer.format.channelCount)
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: data[0], count: frames))
        }
        var out = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            let pointer = data[channel]
            for frame in 0..<frames { out[frame] += pointer[frame] }
        }
        let scale = 1 / Float(channels)
        for frame in 0..<frames { out[frame] *= scale }
        return out
    }

    static func run(_ arguments: [String]) async {
        var file: String?
        var engineName = "parakeet"
        var seconds = 60
        var language: String?
        var vocabulary: [String] = []
        var modelsDir: String?

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--file":
                index += 1
                if index < arguments.count { file = arguments[index] }
            case "--engine":
                index += 1
                if index < arguments.count { engineName = arguments[index] }
            case "--seconds":
                index += 1
                if index < arguments.count { seconds = Int(arguments[index]) ?? seconds }
            case "--language":
                index += 1
                if index < arguments.count { language = arguments[index] }
            case "--vocab":
                index += 1
                if index < arguments.count {
                    vocabulary = VocabularyPrompt.parse(arguments[index])
                }
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
            print(
                "Usage: portavoz-cli bench-live --file <wav|caf> [--engine parakeet|speech] [--seconds N] [--language es] [--vocab \"a,b\"]"
            )
            return
        }

        do {
            let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: file))
            let rate = audioFile.processingFormat.sampleRate
            let totalSeconds = min(
                Double(seconds), Double(audioFile.length) / rate)
            let hints = TranscriptionHints(language: language, vocabulary: vocabulary)

            print("bench-live · \(engineName) · \(Int(totalSeconds))s de \(file)")

            let (stream, feed) = AsyncStream.makeStream(of: AudioChunk.self)
            let segments: AsyncThrowingStream<TranscriptSegment, Error>
            switch engineName {
            case "parakeet":
                let store = CLISupport.modelStore(fromModelsDir: modelsDir)
                let engine = try await CLISupport.loadEngine(store: store)
                segments = engine.transcribe(stream, hints: hints)
            case "speech":
                guard #available(macOS 26.0, *) else {
                    print("error: --engine speech requiere macOS 26")
                    return
                }
                guard SpeechAnalyzerEngine.isAvailable else {
                    print("error: SpeechTranscriber no está disponible en este equipo")
                    return
                }
                let locale = try await SpeechAnalyzerEngine.ensureAssets(
                    language: language) { print($0) }
                print("locale: \(locale.identifier)")
                segments = SpeechAnalyzerEngine().transcribe(
                    stream, hints: hints, locale: locale)
            default:
                print("error: engine desconocido \(engineName) (parakeet|speech)")
                return
            }

            // Feeder: 1 s chunks at real-time pace.
            let feedStart = Date()
            let feeder = Task {
                let chunkFrames = AVAudioFrameCount(rate)
                guard
                    let buffer = AVAudioPCMBuffer(
                        pcmFormat: audioFile.processingFormat, frameCapacity: chunkFrames)
                else { return }
                var fedSeconds = 0.0
                while fedSeconds < totalSeconds {
                    do {
                        try audioFile.read(into: buffer, frameCount: chunkFrames)
                    } catch { break }
                    guard buffer.frameLength > 0 else { break }
                    let samples = monoSamples(from: buffer)
                    feed.yield(
                        AudioChunk(
                            channel: .microphone, samples: samples,
                            sampleRate: rate, timestamp: fedSeconds))
                    fedSeconds += Double(buffer.frameLength) / rate
                    // Real-time pacing: never feed faster than the clock.
                    let target = feedStart.addingTimeInterval(fedSeconds)
                    let wait = target.timeIntervalSinceNow
                    if wait > 0 {
                        try? await Task.sleep(for: .seconds(wait))
                    }
                }
                feed.finish()
            }

            // Consumer: finalization lag per FINAL segment.
            var lags: [Double] = []
            var finals = 0
            var volatiles = 0
            var characters = 0
            var firstResultAt: Double?
            do {
                for try await segment in segments {
                    let elapsed = Date().timeIntervalSince(feedStart)
                    if firstResultAt == nil { firstResultAt = elapsed }
                    if segment.isFinal {
                        finals += 1
                        characters += segment.text.count
                        lags.append(elapsed - segment.endTime)
                        print(String(
                            format: "[%6.2fs] final lag %+5.2fs  %@",
                            elapsed, elapsed - segment.endTime,
                            String(segment.text.prefix(70))))
                    } else {
                        volatiles += 1
                    }
                }
            } catch {
                print("stream error: \(error.localizedDescription)")
            }
            feeder.cancel()

            lags.sort()
            func percentile(_ p: Double) -> Double {
                guard !lags.isEmpty else { return 0 }
                return lags[min(lags.count - 1, Int(Double(lags.count) * p))]
            }
            print("")
            print("finales: \(finals) · volátiles: \(volatiles) · chars: \(characters)")
            if let firstResultAt {
                print(String(format: "primer resultado: %.2fs", firstResultAt))
            }
            print(String(
                format: "lag de finalización — p50 %.2fs · p95 %.2fs · max %.2fs",
                percentile(0.5), percentile(0.95), lags.last ?? 0))
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }
}
