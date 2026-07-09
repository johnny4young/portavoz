import AudioCaptureKit
import Foundation
import PortavozCore
import TranscriptionKit

/// `portavoz-cli bench-m2 --batch-file <wav> [--seconds N] [--mic <name>]
///                        [--language es] [--models-dir <dir>]`
///
/// The M2 acceptance harness: transcribes the microphone live while the
/// batch slot re-transcribes `--batch-file` in a loop, then reports live
/// latency percentiles. Criterion: p95 end-to-end latency < 2 s with the
/// batch slot busy the whole time. Run it with continuous speech playing
/// (podcast) — silence gaps inflate the measured lag.
enum BenchCommand {
    // CLI de desarrollo: el parser de flags es un switch inherentemente largo.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func run(_ arguments: [String]) async {
        var batchFile: String?
        var seconds = 60
        var micIdentifier: String?
        var language: String?
        var modelsDir: String?

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--batch-file":
                index += 1
                if index < arguments.count { batchFile = arguments[index] }
            case "--seconds":
                index += 1
                if index < arguments.count { seconds = Int(arguments[index]) ?? seconds }
            case "--mic":
                index += 1
                if index < arguments.count { micIdentifier = arguments[index] }
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

        guard let batchFile else {
            print(
                // One-line usage text.
                // swiftlint:disable:next line_length
                "Usage: portavoz-cli bench-m2 --batch-file <wav> [--seconds N] [--mic <name>] [--language es] [--models-dir <dir>]"
            )
            return
        }
        let batchURL = URL(fileURLWithPath: batchFile)
        guard FileManager.default.fileExists(atPath: batchURL.path) else {
            print("error: no such file: \(batchURL.path)")
            return
        }

        do {
            let store = CLISupport.modelStore(fromModelsDir: modelsDir)
            let engine = try await CLISupport.loadEngine(store: store)
            let scheduler = TranscriptionScheduler()

            // Batch slot: hammer the file in a loop so the ANE stays
            // contended for the entire live window.
            let batchHints = TranscriptionHints(language: language)
            let batchDone = LockBox(false)
            let batchTask = Task { () -> [Double] in
                var passes: [Double] = []
                while !batchDone.current {
                    do {
                        let result = try await scheduler.batch {
                            try await engine.transcribeFile(at: batchURL, hints: batchHints)
                        }
                        passes.append(result.speedFactor)
                        print(String(
                            format: "  [batch] pass %d done: %.0fx real time",
                            passes.count, result.speedFactor))
                    } catch {
                        print("  ⚠️ batch pass failed: \(error.localizedDescription)")
                        break
                    }
                }
                return passes
            }

            // Live slot: microphone → engine, measuring end-to-end lag per
            // update (wall clock now vs. audio time of the newest token).
            print("Live mic for \(seconds)s while batch loops on \(batchURL.lastPathComponent)…")
            let microphone = MicrophoneSource(deviceIdentifier: micIdentifier)
            let micStream = try await microphone.start()
            let (feed, feedContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
            let wallStart = LockBox<Date?>(nil)

            let feeder = Task { () -> [(freshness: Double, oldest: Double)] in
                let hints = TranscriptionHints(language: language)
                let segments = await scheduler.live {
                    engine.transcribe(feed, hints: hints)
                }
                // Consume segments concurrently with feeding. Two lags per
                // update: freshness (elapsed − endTime: the newest finished
                // word → how far the caption trails the voice — the
                // acceptance metric) and oldest-word (elapsed − startTime:
                // upper bound that also contains the delta's own audio span,
                // reported as a diagnostic).
                let consumer = Task { () -> [(freshness: Double, oldest: Double)] in
                    var samples: [(freshness: Double, oldest: Double)] = []
                    for try await segment in segments {
                        guard let start = wallStart.current else { continue }
                        let elapsed = Date().timeIntervalSince(start)
                        let freshness = elapsed - segment.endTime
                        samples.append((freshness, elapsed - segment.startTime))
                        let mark = segment.isFinal ? "✓" : "…"
                        print(String(format: "  [live +%.1fs] %@ %@", freshness, mark, segment.text))
                    }
                    return samples
                }
                do {
                    for try await chunk in micStream {
                        if wallStart.current == nil { wallStart.set(Date()) }
                        feedContinuation.yield(chunk)
                    }
                } catch {
                    print("  ⚠️ microphone failed: \(error)")
                }
                feedContinuation.finish()
                return (try? await consumer.value) ?? []
            }

            try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            await microphone.stop()
            let lags = await feeder.value

            batchDone.set(true)
            print("  (waiting for the batch pass in flight to finish…)")
            let passes = await batchTask.value

            // Report
            print("")
            print("— M2 acceptance report —")
            if passes.isEmpty {
                print("batch: 0 completed passes")
            } else {
                let speeds = passes.map { String(format: "%.0fx", $0) }.joined(separator: ", ")
                print("batch: \(passes.count) pass(es) — \(speeds)")
            }
            guard !lags.isEmpty else {
                print("live: no updates — was anything audible on the mic?")
                return
            }
            let freshness = lags.map { $0.freshness }.sorted()
            let oldest = lags.map { $0.oldest }.sorted()
            let p95 = CLISupport.percentile(freshness, 0.95)
            print(String(
                format: "live: %d updates — transcript lag p50 %.2fs · p95 %.2fs · max %.2fs",
                lags.count, CLISupport.percentile(freshness, 0.50), p95, freshness.last ?? 0
            ))
            print(String(
                format: "      oldest-word diagnostic (includes each delta's audio span): p95 %.2fs",
                CLISupport.percentile(oldest, 0.95)
            ))
            let pass = p95 < 2.0 && !passes.isEmpty
            print(pass
                ? "M2 acceptance: PASS ✓ (transcript lag p95 < 2.0s with batch slot busy)"
                : "M2 acceptance: FAIL ✗ (need transcript lag p95 < 2.0s and ≥1 batch pass)")
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }
}

/// Tiny cross-task mutable cell; NSLock keeps it Swift-6 clean.
final class LockBox<Value: Sendable>: @unchecked Sendable {
    // Confinement: `value` is only touched under `lock`.
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    var current: Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}
