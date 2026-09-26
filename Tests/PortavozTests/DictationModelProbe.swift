import Foundation
import os
import PortavozCore
import TranscriptionKit

/// Test-only model lane: no microphone, clipboard, settings, database or download.
/// Uses production caption/assembly policies but does NOT stand in for the controller.
enum DictationModelProbe {
    enum Failure: Error, Equatable {
        case invalidInput
        case inputOverflow
        case engineEndedEarly
        case outputOverflow
    }

    typealias Engine = @Sendable (AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptSegment, Error>
    typealias Pace = @Sendable (ContinuousClock.Instant) async throws -> Void

    struct Result: Sendable {
        // Deliberately not Codable: text stays in memory for scoring only.
        let hypothesis: String
        let mappedDeltas: String
        let legacyCleanedText: String
        let frames: Int
        let updates: Int
        let firstUpdateSeconds: Double?
        let inputEndSeconds: Double
        let completionSeconds: Double
    }

    static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    static func run(
        samples: [Float],
        transcribe: @escaping Engine,
        pace: @escaping Pace = { try await ContinuousClock().sleep(until: $0) }
    ) async throws -> Result {
        try DictationPCMFeeder.validate(samples)
        try Task.checkCancellation()
        let (audio, feed) = AsyncStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .bufferingOldest(128))
        let end = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
        let started = ContinuousClock.now
        let segments = transcribe(audio)
        let producer = Task {
            try await produce(samples: samples, feed: feed, started: started, pace: pace, end: end)
        }
        do {
            var captions: [TranscriptSegment] = []
            var mappedTexts: [String] = []
            var firstUpdate: Double?
            var updates = 0
            var emittedBytes = 0
            let coalescer = CaptionCoalescer()
            for try await segment in segments {
                try Task.checkCancellation()
                updates += 1
                emittedBytes += segment.text.utf8.count
                // A broken provider must not turn a bounded clip into unlimited text.
                guard updates <= 10_000, emittedBytes <= 1_000_000 else {
                    throw Failure.outputOverflow
                }
                if firstUpdate == nil { firstUpdate = seconds(started.duration(to: .now)) }
                mappedTexts.append(segment.text)
                coalescer.apply(segment, to: &captions)
            }
            try Task.checkCancellation()
            guard let inputEnd = end.withLock({ $0 }) else {
                producer.cancel()
                // Preserve an input failure, rather than laundering it as successful ASR.
                do { try await producer.value } catch is CancellationError {
                    throw Failure.engineEndedEarly
                }
                throw Failure.engineEndedEarly
            }
            try await producer.value
            let assembled = DictationAssembler.text(
                confirmed: captions.map(\.text).joined(separator: " "), partial: "")
            return Result(
                hypothesis: assembled, mappedDeltas: mappedTexts.joined(separator: " "),
                legacyCleanedText: DictationTextRules.apply(
                    assembled, replacements: [], removeFillers: true),
                frames: samples.count, updates: updates, firstUpdateSeconds: firstUpdate,
                inputEndSeconds: seconds(started.duration(to: inputEnd)),
                completionSeconds: seconds(started.duration(to: .now)))
        } catch {
            producer.cancel()
            feed.finish()
            _ = try? await producer.value
            throw error
        }
    }

    static func produce(
        samples: [Float], feed: AsyncStream<AudioChunk>.Continuation,
        started: ContinuousClock.Instant, pace: Pace,
        end: OSAllocatedUnfairLock<ContinuousClock.Instant?>
    ) async throws {
        defer { feed.finish() }
        try await DictationPCMFeeder.feed(samples: samples, started: started, pace: pace) { chunk in
            switch feed.yield(chunk) {
            case .enqueued: break
            case .dropped: throw Failure.inputOverflow
            case .terminated: throw Failure.engineEndedEarly
            @unknown default: throw Failure.inputOverflow
            }
        }
        end.withLock { $0 = .now }
    }

    struct Score: Codable, Equatable {
        let wordErrorRate: Double
        let characterErrorRate: Double
        let referenceWords: Int
        let hypothesisWords: Int
        let exactReferenceMatch: Bool
        let legacyCleanupChangedText: Bool
    }

    static func score(_ result: Result, references: [String]) throws -> Score {
        try score(hypothesis: result.hypothesis, legacyCleanedText: result.legacyCleanedText, references: references)
    }

    static func score(hypothesis: String, legacyCleanedText: String, references: [String]) throws -> Score {
        guard !references.isEmpty else { throw Failure.invalidInput }
        let reports = references.map {
            TranscriptionAccuracy.report(reference: $0, hypothesis: hypothesis)
        }
        guard let best = reports.min(by: {
                if $0.wordErrorRate != $1.wordErrorRate { return $0.wordErrorRate < $1.wordErrorRate }
                return $0.characterErrorRate < $1.characterErrorRate
        }) else { throw Failure.invalidInput }
        return Score(
            wordErrorRate: best.wordErrorRate, characterErrorRate: best.characterErrorRate,
            referenceWords: best.referenceWords, hypothesisWords: best.hypothesisWords,
            exactReferenceMatch: references.contains(hypothesis),
            legacyCleanupChangedText: hypothesis != legacyCleanedText)
    }
}
