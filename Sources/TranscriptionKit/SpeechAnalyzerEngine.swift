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

/// Gives the SpeechAnalyzer input feeder lexical ownership beneath the result
/// consumer. Leaving the scope cancels and drains the feeder before returning,
/// including when the consumer throws or its parent task is cancelled.
enum SpeechAnalyzerFeedScope {
    static func run<FeederResult: Sendable>(
        feeder: @escaping @Sendable () async -> FeederResult,
        consuming results: () async throws -> Void
    ) async throws -> FeederResult? {
        try await withThrowingTaskGroup(of: FeederResult.self) { group in
            group.addTask(operation: feeder)
            defer { group.cancelAll() }

            try await results()
            group.cancelAll()
            return try await group.next()
        }
    }
}

actor SpeechAnalyzerCancellationGate {
    private let operation: @Sendable () async -> Void
    private var cancellationStarted = false
    private var cancellationFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(operation: @escaping @Sendable () async -> Void) {
        self.operation = operation
    }

    func cancel() async {
        if cancellationFinished { return }
        if cancellationStarted {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
            return
        }

        cancellationStarted = true
        await operation()
        cancellationFinished = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for continuation in pending {
            continuation.resume()
        }
    }
}

/// Bridges AVFoundation's non-Sendable audio buffer into the converter's
/// `@Sendable` input callback. The buffer is fully initialized before entering
/// this box and is never mutated afterward; the lock serializes the callback's
/// one-shot state. The unchecked conformance is intentionally limited to this
/// SDK boundary rather than weakening the whole AVFoundation import.
private final class AudioConverterInputBox: @unchecked Sendable {
    private let lock = NSLock()
    private let source: AVAudioPCMBuffer
    private var delivered = false

    init(source: AVAudioPCMBuffer) {
        self.source = source
    }

    func nextBuffer(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !delivered else {
            status.pointee = .noDataNow
            return nil
        }
        delivered = true
        status.pointee = .haveData
        return source
    }
}

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
            supporting: [transcriber]) {
            progress?("Descargando modelo de voz de macOS para \(locale.identifier)…")
            try await request.downloadAndInstall()
        }
        return locale
    }

    // Live transcription loop (analyzer setup + stream consumption + result
    // mapping); the body is legitimately long.
    /// Live transcription with the same shape as `ParakeetEngine.transcribe`
    /// so both engines can be driven (and benchmarked) identically.
    public func transcribe( // swiftlint:disable:this function_body_length
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

                    let analyzer = SpeechAnalyzer(
                        inputSequence: inputSequence,
                        modules: [transcriber],
                        analysisContext: context)
                    let cancellationGate = SpeechAnalyzerCancellationGate {
                        await analyzer.cancelAndFinishNow()
                    }

                    // The feeder ALSO finalizes when the input ends: the
                    // results loop below only terminates when someone
                    // finalizes the analysis — sequencing the finalize
                    // after the loop deadlocked the first bench run
                    // (results parked forever once the audio ran out).
                    let inputFinished: Bool
                    do {
                        inputFinished = try await withTaskCancellationHandler {
                            try await SpeechAnalyzerFeedScope.run(
                                feeder: {
                                    await Self.feed(
                                        audio,
                                        to: analyzer,
                                        format: analyzerFormat,
                                        continuation: inputContinuation)
                                },
                                consuming: {
                                    try await Self.consume(
                                        transcriber,
                                        meetingID: meetingID,
                                        language: language
                                            ?? locale.language.languageCode?.identifier,
                                        continuation: continuation,
                                        cancellationGate: cancellationGate)
                                }) ?? false
                        } onCancel: {
                            Task { await cancellationGate.cancel() }
                        }
                    } catch {
                        await cancellationGate.cancel()
                        throw error
                    }
                    guard inputFinished, !Task.isCancelled else {
                        await cancellationGate.cancel()
                        throw CancellationError()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in job.cancel() }
        }
    }

    private static func feed(
        _ audio: AsyncStream<AudioChunk>,
        to analyzer: SpeechAnalyzer,
        format: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) async -> Bool {
        var converter: AVAudioConverter?
        defer { continuation.finish() }
        for await chunk in audio {
            guard !Task.isCancelled else { return false }
            guard
                let buffer = pcmBuffer(
                    from: chunk,
                    to: format,
                    converter: &converter)
            else { continue }
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        guard !Task.isCancelled else { return false }
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private static func consume(
        _ transcriber: SpeechTranscriber,
        meetingID: MeetingID,
        language: String?,
        continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation,
        cancellationGate: SpeechAnalyzerCancellationGate
    ) async throws {
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                continuation.yield(
                    TranscriptSegment(
                        meetingID: meetingID,
                        channel: .microphone,
                        text: text,
                        language: language,
                        startTime: result.range.start.seconds,
                        endTime: result.range.end.seconds,
                        isFinal: result.isFinal
                    ))
            }
        } catch {
            // Cancel the analyzer before this error leaves the structured
            // scope: its feeder may currently be awaiting finalization.
            await cancellationGate.cancel()
            throw error
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
            !chunk.samples.isEmpty,
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
            guard let baseAddress = pointer.baseAddress else { return }
            channelData[0].update(from: baseAddress, count: chunk.samples.count)
        }

        if sourceFormat == format { return source }

        if converter == nil || converter?.inputFormat != sourceFormat
            || converter?.outputFormat != format {
            converter = AVAudioConverter(from: sourceFormat, to: format)
        }
        guard let converter else { return nil }

        let ratio = format.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(chunk.samples.count) * ratio).rounded(.up) + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        else { return nil }

        let input = AudioConverterInputBox(source: source)
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            input.nextBuffer(status: status)
        }
        guard conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
#endif
