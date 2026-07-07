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

    /// Ensures model + tokenizer are downloaded/verified, then loads.
    public static func loadRecommended(
        store: ModelStore,
        progress: (@Sendable (ModelStore.DownloadProgress) -> Void)? = nil
    ) async throws -> WhisperEngine {
        let modelDirectory = try await store.ensureAvailable(
            ModelCatalog.whisperLargeV3Turbo, progress: progress)
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
            let tokenizer = pipe.tokenizer
        {
            promptTokens = tokenizer.encode(text: " " + prompt)
        }
        let options = DecodingOptions(
            task: .transcribe,
            language: hints.language,
            temperature: 0,
            promptTokens: promptTokens,
            chunkingStrategy: .vad
        )
        let started = Date()
        let results = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)
        let processingTime = Date().timeIntervalSince(started)

        let meetingID = hints.meetingID ?? MeetingID()
        var segments: [TranscriptSegment] = []
        // timings.inputAudioSeconds under-reports with VAD chunking; the
        // file itself is the truth.
        var duration: TimeInterval = 0
        if let audioFile = try? AVAudioFile(forReading: url) {
            duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        }
        for result in results {
            for segment in result.segments {
                let text = Self.cleanSegmentText(segment.text)
                guard !text.isEmpty else { continue }
                segments.append(
                    TranscriptSegment(
                        meetingID: meetingID,
                        channel: channel,
                        text: text,
                        language: hints.language ?? result.language,
                        startTime: TimeInterval(segment.start),
                        endTime: TimeInterval(segment.end),
                        confidence: min(1, Double(exp(segment.avgLogprob))),
                        isFinal: true
                    ))
            }
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
