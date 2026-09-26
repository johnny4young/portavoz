import Foundation
import PortavozCore

#if canImport(Speech)
import Speech

/// Only a ready, already installed locale may start an Apple live session.
/// Preparing a missing asset is a separate explicit user action.
public enum SpeechAnalyzerLiveReadiness: Equatable, Error, Sendable {
    case unavailable
    case languageRequired
    case unsupported(String)
    case needsDownload(String)
    case ready(String)

    static func resolve(
        requested: String?,
        available: Bool,
        supported: String?,
        installed: [String]
    ) -> Self {
        guard let requested, requested == "en" || requested == "es" else {
            return .languageRequired
        }
        guard available else { return .unavailable }
        guard let supported,
              Locale(identifier: supported).language.languageCode?.identifier == requested
        else { return .unsupported(requested) }
        if installed.contains(supported) { return .ready(supported) }
        if let installedEquivalent = installed.sorted().first(where: {
            Locale(identifier: $0).language.languageCode?.identifier == requested
        }) {
            return .ready(installedEquivalent)
        }
        return .needsDownload(supported)
    }
}

/// Adapts Apple's range-based results to the append-only live transcript
/// contract. Volatile range revisions cannot enter CaptionCoalescer: joining
/// them as deltas would turn a corrected phrase into a false duplicate.
@available(macOS 26.0, iOS 26.0, *)
public struct SpeechAnalyzerLiveEngine: TranscriptionEngine {
    public let descriptor: EngineDescriptor
    public let locale: Locale

    private let source: @Sendable (
        AsyncStream<AudioChunk>, TranscriptionHints
    ) -> AsyncThrowingStream<TranscriptSegment, Error>

    /// Read-only capability probe. It never calls AssetInventory or starts a
    /// download; the app runs it in a bundle with Speech authorization.
    public static func readiness(language: String?) async throws -> SpeechAnalyzerLiveReadiness {
        guard let language, language == "en" || language == "es" else {
            return .languageRequired
        }
        guard SpeechTranscriber.isAvailable else { return .unavailable }
        try Task.checkCancellation()
        let requested = Locale(identifier: language)
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        try Task.checkCancellation()
        let installed = await SpeechTranscriber.installedLocales
        try Task.checkCancellation()
        return SpeechAnalyzerLiveReadiness.resolve(
            requested: language,
            available: true,
            supported: supported?.identifier,
            installed: installed.map(\.identifier))
    }

    /// The serving constructor never prepares assets implicitly. A caller
    /// may offer the explicit Settings preparation action after this typed
    /// readiness failure, but must not start capture as if Apple Speech worked.
    public static func acquireInstalled(language: String?) async throws -> Self {
        let state = try await readiness(language: language)
        guard case .ready(let localeID) = state else { throw state }
        return Self(installedLocale: Locale(identifier: localeID))
    }

    init(installedLocale locale: Locale) {
        self.init(locale: locale) { audio, hints in
            SpeechAnalyzerEngine().transcribe(audio, hints: hints, locale: locale)
        }
    }

    init(
        locale: Locale,
        source: @escaping @Sendable (
            AsyncStream<AudioChunk>, TranscriptionHints
        ) -> AsyncThrowingStream<TranscriptSegment, Error>
    ) {
        self.locale = locale
        self.source = source
        descriptor = EngineDescriptor(
            id: "apple-speech-analyzer-\(locale.identifier)",
            displayName: "Apple Speech (\(locale.identifier))",
            languages: [locale.identifier],
            realTimeFactor: nil,
            runsOnDevice: true,
            approximateMemoryMB: nil)
    }

    public func transcribe(
        _ audio: AsyncStream<AudioChunk>, hints: TranscriptionHints
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var gate = SpeechAnalyzerFinalResultGate()
                do {
                    for try await segment in source(audio, hints) {
                        try Task.checkCancellation()
                        if try gate.accept(segment) {
                            var revision = segment
                            revision.liveUpdateMode = .rangeRevision
                            continuation.yield(revision)
                        }
                    }
                    try Task.checkCancellation()
                    try gate.finish()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Final SpeechTranscriber ranges must not rewrite an already emitted range.
/// Rejecting an overlap is safer than delivering a false fact or inserting it.
struct SpeechAnalyzerFinalResultGate {
    private var lastEnd: TimeInterval?
    private var pendingVolatileRanges: [Range<TimeInterval>] = []

    mutating func accept(_ segment: TranscriptSegment) throws -> Bool {
        guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard segment.startTime.isFinite,
              segment.endTime.isFinite,
              segment.startTime >= 0,
              segment.endTime >= segment.startTime
        else {
            throw TranscriptionError.engineUnavailable(
                "Apple Speech returned an invalid live range")
        }
        if !segment.isFinal {
            guard lastEnd.map({ segment.startTime >= $0 }) ?? true else { return false }
            // A newer volatile result can replace an earlier range rather
            // than append to it. Keep only its still-unconfirmed coverage.
            pendingVolatileRanges.removeAll { $0.lowerBound == segment.startTime }
            pendingVolatileRanges.append(segment.startTime..<segment.endTime)
            return true
        }
        guard lastEnd.map({ segment.startTime >= $0 }) ?? true else {
            throw TranscriptionError.engineUnavailable(
                "Apple Speech returned a non-monotonic final result")
        }
        lastEnd = segment.endTime
        pendingVolatileRanges = pendingVolatileRanges.flatMap { pending -> [Range<TimeInterval>] in
            guard pending.overlaps(segment.startTime..<segment.endTime) else { return [pending] }
            var remaining: [Range<TimeInterval>] = []
            if pending.lowerBound < segment.startTime {
                remaining.append(pending.lowerBound..<segment.startTime)
            }
            if segment.endTime < pending.upperBound {
                remaining.append(segment.endTime..<pending.upperBound)
            }
            return remaining
        }
        return true
    }

    func finish() throws {
        guard pendingVolatileRanges.isEmpty else {
            throw TranscriptionError.engineUnavailable(
                "Apple Speech ended with unconfirmed live text")
        }
    }
}
#endif
