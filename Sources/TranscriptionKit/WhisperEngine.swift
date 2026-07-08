import AVFoundation
import Foundation
import ModelStoreKit
import PortavozCore
import WhisperKit

/// Whisper large-v3-turbo via WhisperKit — the quality re-pass (D7:
/// `finalTranscription`). Slower and heavier than Parakeet on purpose:
/// it runs once, after the meeting, and replaces the live transcript.
///
/// Both the CoreML model and the tokenizer load from directories the
/// `ModelStore` verified; WhisperKit is configured to never download.
public actor WhisperEngine {
    private let pipe: WhisperKit

    private init(pipe: WhisperKit) {
        self.pipe = pipe
    }

    /// Ensures model + tokenizer are downloaded/verified, then loads. The
    /// descriptor selects the quality vs. disk trade-off (turbo 1.6 GB vs.
    /// the 626 MB compact variant, M12).
    public static func loadRecommended(
        store: ModelStore,
        descriptor: ModelDescriptor = ModelCatalog.whisperLargeV3Turbo,
        progress: (@Sendable (ModelStore.DownloadProgress) -> Void)? = nil
    ) async throws -> WhisperEngine {
        let modelDirectory = try await store.ensureAvailable(
            descriptor, progress: progress)
        let tokenizerDirectory = try await store.ensureAvailable(
            ModelCatalog.whisperTokenizer, progress: progress)

        let config = WhisperKitConfig(
            modelFolder: modelDirectory.path,
            tokenizerFolder: tokenizerDirectory,
            verbose: false,
            load: true,
            download: false
        )
        let pipe = try await WhisperKit(config)
        return WhisperEngine(pipe: pipe)
    }

    /// Batch quality transcription. Segments come out sentence-sized with
    /// Whisper's native punctuation and timestamps.
    public func transcribeFile(
        at url: URL,
        hints: TranscriptionHints = TranscriptionHints(),
        channel: AudioChannel = .system
    ) async throws -> FileTranscription {
        // Domain vocabulary rides in as conditioning context (biasing, not
        // forcing); WhisperKit filters special tokens out of the prompt.
        var promptTokens: [Int]?
        if let prompt = VocabularyPrompt.text(hints.vocabulary),
            let tokenizer = pipe.tokenizer {
            promptTokens = tokenizer.encode(text: " " + prompt)
        }
        let options = DecodingOptions(
            task: .transcribe,
            language: hints.language,
            temperature: 0,
            promptTokens: promptTokens,
            // The default (16!) races the workers over shared decoder state
            // and chunks vanish SILENTLY: a real 482 s meeting collapsed to
            // 3 segments, non-deterministically, with zero errors surfaced.
            // One worker is correct and cheap — the ANE serializes anyway.
            concurrentWorkerCount: 1,
            chunkingStrategy: .vad
        )
        let started = Date()
        // Load + peak-normalize ourselves: WhisperKit's energy VAD has an
        // absolute threshold and quiet meetings sit right at it.
        var samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        AudioLevel.normalizePeak(&samples)
        let meetingID = hints.meetingID ?? MeetingID()

        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        var segments = Self.buildSegments(
            from: results, meetingID: meetingID, channel: channel, language: hints.language)

        // The VAD-chunked path SWALLOWS failed chunks (they only reach the
        // debug log), so a systematic per-chunk failure looks like a mostly
        // silent meeting — a real 482 s recording came back as 3 segments.
        // Coverage must be measured on the CLEANED segments: poisoned
        // chunks return valid-looking timespans whose text cleans to
        // nothing. When the fast path covers suspiciously little audio,
        // redo it sequentially — that path decodes every window and
        // propagates errors — and WITHOUT the vocabulary prompt:
        // conditioning that doesn't match a window derails its decoding
        // wholesale (observed: with the glossary prompt only the chunk
        // that actually mentioned its terms survived). A full unbiased
        // transcript beats a biased sliver.
        let fileDuration = Double(samples.count) / Double(WhisperKit.sampleRate)
        if fileDuration > 60, Self.coverage(of: segments) < fileDuration * 0.2 {
            var sequential = options
            sequential.chunkingStrategy = nil
            sequential.promptTokens = nil
            let retried = try await pipe.transcribe(
                audioArray: samples, decodeOptions: sequential)
            let rebuilt = Self.buildSegments(
                from: retried, meetingID: meetingID, channel: channel,
                language: hints.language)
            if Self.coverage(of: rebuilt) > Self.coverage(of: segments) {
                segments = rebuilt
            }
        }
        let processingTime = Date().timeIntervalSince(started)

        // timings.inputAudioSeconds under-reports with VAD chunking; the
        // file itself is the truth.
        var duration: TimeInterval = 0
        if let audioFile = try? AVAudioFile(forReading: url) {
            duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        }
        segments.sort { $0.startTime < $1.startTime }
        let text = segments.map(\.text).joined(separator: " ")

        return FileTranscription(
            text: text,
            segments: segments,
            audioDuration: duration,
            processingTime: processingTime
        )
    }

    static func buildSegments(
        from results: [TranscriptionResult],
        meetingID: MeetingID,
        channel: AudioChannel,
        language: String?
    ) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for result in results {
            for segment in result.segments {
                let text = Self.cleanSegmentText(segment.text)
                guard !text.isEmpty else { continue }
                segments.append(
                    TranscriptSegment(
                        meetingID: meetingID,
                        channel: channel,
                        text: text,
                        language: language ?? result.language,
                        startTime: TimeInterval(segment.start),
                        endTime: TimeInterval(segment.end),
                        confidence: min(1, Double(exp(segment.avgLogprob))),
                        isFinal: true
                    ))
            }
        }
        return segments
    }

    static func coverage(of segments: [TranscriptSegment]) -> Double {
        segments.reduce(0.0) { $0 + ($1.endTime - $1.startTime) }
    }

    /// Whisper segment text carries special tokens like `<|0.00|>`.
    static func cleanSegmentText(_ text: String) -> String {
        var cleaned = text
        while let start = cleaned.range(of: "<|"), let end = cleaned.range(of: "|>") {
            guard start.lowerBound < end.upperBound else { break }
            cleaned.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
