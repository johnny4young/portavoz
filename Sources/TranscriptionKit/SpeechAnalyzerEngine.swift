import AVFoundation
import Foundation
import PortavozCore

public enum TranscriptionError: Error, LocalizedError, Sendable {
    case engineUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .engineUnavailable(let reason): return reason
        }
    }
}

#if canImport(Speech)
import Speech

/// Apple's `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26) in the LIVE
/// role — the spike that answers D25's open architecture question: does
/// the OS engine compete with Parakeet for captions? Zero download when
/// the locale asset is installed, streaming via `volatileResults`, and —
/// verified against the local SDK, correcting earlier research — it DOES
/// take custom vocabulary (`AnalysisContext.contextualStrings`).
///
/// Emission model differs from Parakeet on purpose: Parakeet emits
/// append-only DELTAS; SpeechTranscriber emits results that cover a time
/// range — volatile ones get replaced, finalized ones are stable. This
/// engine forwards them as `TranscriptSegment`s with `isFinal` mapped, and
/// leaves the append-vs-replace UI question to the M12 integration.
@available(macOS 26.0, iOS 26.0, *)
public struct SpeechAnalyzerEngine: Sendable {
    public init() {}

    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// Resolves the closest supported locale and downloads its model asset
    /// if missing (one-time, Apple-hosted — the "zero download" claim only
    /// holds once the OS has the locale installed).
    public static func ensureAssets(
        language: String?,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Locale {
        let requested = Locale(identifier: language ?? Locale.current.identifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        else {
            throw TranscriptionError.engineUnavailable(
                "SpeechTranscriber no soporta el idioma '\(requested.identifier)'")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber])
        {
            progress?("Descargando modelo de voz de macOS para \(locale.identifier)…")
            try await request.downloadAndInstall()
        }
        return locale
    }

    /// Live transcription with the same shape as `ParakeetEngine.transcribe`
    /// so both engines can be driven (and benchmarked) identically.
    public func transcribe(
        _ audio: AsyncStream<AudioChunk>,
        hints: TranscriptionHints,
        locale: Locale
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        let meetingID = hints.meetingID ?? MeetingID()
        let vocabulary = hints.vocabulary
        let language = hints.language

        return AsyncThrowingStream { continuation in
            let job = Task {
                do {
                    let transcriber = SpeechTranscriber(
                        locale: locale,
                        transcriptionOptions: [],
                        reportingOptions: [.volatileResults, .fastResults],
                        attributeOptions: [.audioTimeRange])

                    let context = AnalysisContext()
                    if !vocabulary.isEmpty {
                        context.contextualStrings[.general] = vocabulary
                    }

                    guard
                        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                            compatibleWith: [transcriber])
                    else {
                        throw TranscriptionError.engineUnavailable(
                            "SpeechAnalyzer no ofrece formato de audio compatible")
                    }

                    // Bridge AudioChunk → AnalyzerInput, converting to the
                    // analyzer's format (typically ≠ the capture rate).
                    let (inputSequence, inputContinuation) =
                        AsyncStream.makeStream(of: AnalyzerInput.self)
                    let feeder = Task {
                        var converter: AVAudioConverter?
                        for await chunk in audio {
                            guard
                                let buffer = Self.pcmBuffer(
                                    from: chunk, to: analyzerFormat, converter: &converter)
                            else { continue }
                            inputContinuation.yield(AnalyzerInput(buffer: buffer))
                        }
                        inputContinuation.finish()
                    }

                    let analyzer = SpeechAnalyzer(
                        inputSequence: inputSequence,
                        modules: [transcriber],
                        analysisContext: context)

                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                            continue
                        }
                        continuation.yield(
                            TranscriptSegment(
                                meetingID: meetingID,
                                channel: .microphone,
                                text: text,
                                language: language ?? locale.language.languageCode?.identifier,
                                startTime: result.range.start.seconds,
                                endTime: result.range.end.seconds,
                                isFinal: result.isFinal
                            ))
                    }
                    feeder.cancel()
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in job.cancel() }
        }
    }

    /// Float-mono `AudioChunk` → `AVAudioPCMBuffer` in the analyzer's
    /// format, reusing one `AVAudioConverter` across chunks.
    private static func pcmBuffer(
        from chunk: AudioChunk,
        to format: AVAudioFormat,
        converter: inout AVAudioConverter?
    ) -> AVAudioPCMBuffer? {
        guard
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: chunk.sampleRate,
                channels: 1,
                interleaved: false),
            let source = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(chunk.samples.count)),
            let channelData = source.floatChannelData
        else { return nil }
        source.frameLength = AVAudioFrameCount(chunk.samples.count)
        chunk.samples.withUnsafeBufferPointer { pointer in
            channelData[0].update(from: pointer.baseAddress!, count: chunk.samples.count)
        }

        if sourceFormat == format { return source }

        if converter == nil || converter?.inputFormat != sourceFormat
            || converter?.outputFormat != format
        {
            converter = AVAudioConverter(from: sourceFormat, to: format)
        }
        guard let converter else { return nil }

        let ratio = format.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(chunk.samples.count) * ratio).rounded(.up) + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        else { return nil }

        var fed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return source
        }
        guard conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
#endif
