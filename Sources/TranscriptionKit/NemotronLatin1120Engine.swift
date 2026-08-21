import AVFoundation
import FluidAudio
import Foundation
import ModelStoreKit
import PortavozCore

/// Fail-closed boundary errors for the research-only Nemotron challenger.
public enum NemotronLatin1120Error: Error, Equatable, LocalizedError, Sendable {
    case languageRequired
    case unsupportedLanguage(String)
    case vocabularyUnsupported
    case invalidAudioChunk(index: Int)
    case invalidModelLayout(String)
    case invalidTokenTiming(index: Int)
    case timingCursorRegressed(emitted: Int, available: Int)

    public var errorDescription: String? {
        switch self {
        case .languageRequired:
            return "Nemotron Latin benchmarking requires an explicit en or es language"
        case .unsupportedLanguage(let language):
            return "Nemotron Latin benchmarking does not support language \(language); use en or es"
        case .vocabularyUnsupported:
            return "Nemotron Latin benchmarking does not support vocabulary prompts"
        case .invalidAudioChunk(let index):
            return "invalid audio chunk at index \(index)"
        case .invalidModelLayout(let path):
            return "unverified Nemotron model layout entry: \(path)"
        case .invalidTokenTiming(let index):
            return "Nemotron returned an invalid token timing at index \(index)"
        case .timingCursorRegressed(let emitted, let available):
            return "Nemotron timing cursor regressed from \(emitted) emitted tokens to \(available) available"
        }
    }
}

/// Opt-in Latin 1120 ms Nemotron adapter used only by `bench-live` (D355).
///
/// The product router continues to serve Parakeet. This adapter preloads one
/// immutable CoreML graph set and creates isolated decoder/cache state for
/// every stream. That avoids both O(streams) model residency and cross-stream
/// state races. It emits only newly appended stable RNN-T token timings.
public final class NemotronLatin1120Engine: TranscriptionEngine, Sendable {
    public let descriptor = EngineDescriptor(
        id: "nemotron-3.5-asr-latin-1120ms",
        displayName: "Nemotron 3.5 ASR Latin 1120 ms",
        languages: ["en", "es"],
        // Rounded from upstream's machine-dependent 66x aggregate result.
        // Portavoz decisions must use LiveTranscriptionBench, not this hint.
        realTimeFactor: 0.02,
        runsOnDevice: true,
        // Upstream's shared-model estimate is ~1.5 GB plus per-stream state.
        approximateMemoryMB: 1_600
    )

    private let models: SharedNemotronMultilingualModels

    private init(models: SharedNemotronMultilingualModels) {
        self.models = models
    }

    /// Loads only after the caller supplies a directory verified against the
    /// exact D355 artifact descriptor. Direct arbitrary-path loading is kept
    /// out of the public API because CoreML model files are executable input.
    public static func load(
        fromVerifiedDirectory directory: URL
    ) async throws -> NemotronLatin1120Engine {
        try NemotronModelLayout.validate(directory: directory)
        let models = try await StreamingNemotronMultilingualAsrManager.preloadShared(
            from: directory)
        return NemotronLatin1120Engine(models: models)
    }

    /// Explicit research entry point. It is intentionally not used by any app
    /// composition root or by `ModelCatalog.recommended(for:)`.
    public static func loadResearchCandidate(
        store: ModelStore,
        progress: (@Sendable (ModelStore.DownloadProgress) -> Void)? = nil
    ) async throws -> NemotronLatin1120Engine {
        let directory = try await store.ensureAvailable(
            ModelCatalog.nemotronLatin1120,
            progress: progress)
        return try await load(fromVerifiedDirectory: directory)
    }

    public func transcribe(
        _ audio: AsyncStream<AudioChunk>,
        hints: TranscriptionHints
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        let models = self.models
        return AsyncThrowingStream { continuation in
            let job = Task {
                let manager = StreamingNemotronMultilingualAsrManager()
                do {
                    let language = try Self.validate(hints: hints)

                    try await manager.loadFromShared(models)
                    await manager.setLanguage(language)

                    let meetingID = hints.meetingID ?? MeetingID()
                    var emittedTimingCount = 0
                    var fedDuration: TimeInterval = 0
                    var lastChannel: AudioChannel = .microphone
                    var chunkIndex = 0

                    for await chunk in audio {
                        try Task.checkCancellation()
                        defer { chunkIndex += 1 }
                        guard let buffer = try Self.validatedBuffer(
                            for: chunk,
                            index: chunkIndex)
                        else { continue }

                        lastChannel = chunk.channel
                        fedDuration += chunk.duration
                        _ = try await manager.process(audioBuffer: buffer)
                        let timings = await manager.getTokenTimings()
                        if let segment = try NemotronSegmentMapper.segment(
                            timings: timings,
                            emittedCount: emittedTimingCount,
                            meetingID: meetingID,
                            channel: lastChannel,
                            language: language) {
                            continuation.yield(segment)
                        }
                        emittedTimingCount = timings.count
                    }

                    try Task.checkCancellation()
                    let final = try await manager.finishWithTokenTimings()
                    if let segment = try NemotronSegmentMapper.finalSegment(
                        text: final.text,
                        timings: final.timings,
                        emittedCount: emittedTimingCount,
                        audioDuration: fedDuration,
                        meetingID: meetingID,
                        channel: lastChannel,
                        language: language) {
                        continuation.yield(segment)
                    }
                    await manager.cleanup()
                    continuation.finish()
                } catch {
                    await manager.cleanup()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in job.cancel() }
        }
    }

    /// Validates capabilities before a caller starts a large model download.
    /// Returns the exact upstream prompt key used for the run.
    public static func validate(hints: TranscriptionHints) throws -> String {
        guard !hints.vocabulary.contains(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw NemotronLatin1120Error.vocabularyUnsupported
        }
        return try languagePrompt(for: hints.language)
    }

    private static func validatedBuffer(
        for chunk: AudioChunk,
        index: Int
    ) throws -> AVAudioPCMBuffer? {
        guard !chunk.samples.isEmpty else { return nil }
        guard
            chunk.sampleRate.isFinite,
            chunk.sampleRate > 0,
            chunk.samples.allSatisfy(\.isFinite),
            let buffer = chunk.pcmBuffer()
        else {
            throw NemotronLatin1120Error.invalidAudioChunk(index: index)
        }
        return buffer
    }

    private static func languagePrompt(for language: String?) throws -> String {
        guard let language else { throw NemotronLatin1120Error.languageRequired }
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard let root = normalized.split(separator: "-", maxSplits: 1).first,
            !root.isEmpty
        else {
            throw NemotronLatin1120Error.languageRequired
        }
        switch root.lowercased() {
        case "en": return "en"
        case "es": return "es"
        default: throw NemotronLatin1120Error.unsupportedLanguage(language)
        }
    }
}

/// Pure cursor-based projection of cumulative Nemotron timings. An integer
/// cursor is required: adjacent RNN-T tokens may legitimately share a time,
/// so time-edge deduplication would silently lose text.
enum NemotronSegmentMapper {
    static func segment(
        timings: [TokenTiming],
        emittedCount: Int,
        meetingID: MeetingID,
        channel: AudioChannel,
        language: String
    ) throws -> TranscriptSegment? {
        guard emittedCount <= timings.count else {
            throw NemotronLatin1120Error.timingCursorRegressed(
                emitted: emittedCount,
                available: timings.count)
        }
        guard emittedCount < timings.count else { return nil }

        let fresh = Array(timings.dropFirst(emittedCount))
        let previous = emittedCount > 0 ? timings[emittedCount - 1] : nil
        try validate(
            timings: fresh,
            baseIndex: emittedCount,
            previous: previous)
        let text = ParakeetSegmentMapper.joinedText(of: fresh)
        guard !text.isEmpty, let first = fresh.first, let last = fresh.last else {
            return nil
        }
        let meanConfidence = fresh.reduce(0.0) { $0 + Double($1.confidence) }
            / Double(fresh.count)
        return TranscriptSegment(
            meetingID: meetingID,
            channel: channel,
            text: text,
            language: language,
            startTime: first.startTime,
            endTime: last.endTime,
            confidence: min(1, max(0, meanConfidence)),
            isFinal: true)
    }

    static func finalSegment( // swiftlint:disable:this function_parameter_count
        text: String,
        timings: [TokenTiming],
        emittedCount: Int,
        audioDuration: TimeInterval,
        meetingID: MeetingID,
        channel: AudioChannel,
        language: String
    ) throws -> TranscriptSegment? {
        if let segment = try segment(
            timings: timings,
            emittedCount: emittedCount,
            meetingID: meetingID,
            channel: channel,
            language: language) {
            return segment
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard emittedCount == 0, timings.isEmpty, !trimmed.isEmpty else { return nil }
        let boundedDuration = audioDuration.isFinite ? max(0, audioDuration) : 0
        return TranscriptSegment(
            meetingID: meetingID,
            channel: channel,
            text: trimmed,
            language: language,
            startTime: 0,
            endTime: boundedDuration,
            confidence: nil,
            isFinal: true)
    }

    private static func validate(
        timings: [TokenTiming],
        baseIndex: Int,
        previous: TokenTiming?
    ) throws {
        var previous = previous
        for (offset, timing) in timings.enumerated() {
            let startsAfterPrevious = if let previous {
                timing.startTime >= previous.startTime
            } else { true }
            let endsAfterPrevious = if let previous {
                timing.endTime >= previous.endTime
            } else { true }
            guard
                timing.startTime.isFinite,
                timing.endTime.isFinite,
                timing.startTime >= 0,
                timing.endTime >= timing.startTime,
                timing.confidence.isFinite,
                startsAfterPrevious,
                endsAfterPrevious
            else {
                throw NemotronLatin1120Error.invalidTokenTiming(index: baseIndex + offset)
            }
            previous = timing
        }
    }
}

/// Exact directory fence around FluidAudio's optional-model discovery. A
/// verified required subset is insufficient if an unlisted fused/bare bundle
/// can sit beside it and take precedence at load time.
enum NemotronModelLayout {
    static func validate(
        directory: URL,
        descriptor: ModelDescriptor = ModelCatalog.nemotronLatin1120,
        fileManager: FileManager = .default
    ) throws {
        let rootValues = try directory.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey
        ])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw NemotronLatin1120Error.invalidModelLayout(".")
        }
        let expectedFiles = Set(descriptor.artifacts.map(\.path))
        let expectedDirectories = Set(expectedFiles.flatMap(parentDirectories))
        var discoveredFiles: Set<String> = []
        var pending = [directory]

        while let current = pending.popLast() {
            let entries = try fileManager.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey
                ],
                options: [])
            for entry in entries {
                let relativePath = try relativePath(of: entry, under: directory)
                let values = try entry.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey
                ])
                guard values.isSymbolicLink != true else {
                    throw NemotronLatin1120Error.invalidModelLayout(relativePath)
                }
                if values.isDirectory == true {
                    guard expectedDirectories.contains(relativePath) else {
                        throw NemotronLatin1120Error.invalidModelLayout(relativePath)
                    }
                    pending.append(entry)
                } else if values.isRegularFile == true {
                    guard expectedFiles.contains(relativePath) else {
                        throw NemotronLatin1120Error.invalidModelLayout(relativePath)
                    }
                    discoveredFiles.insert(relativePath)
                } else {
                    throw NemotronLatin1120Error.invalidModelLayout(relativePath)
                }
            }
        }

        if let missing = expectedFiles.subtracting(discoveredFiles).min() {
            throw NemotronLatin1120Error.invalidModelLayout(missing)
        }
    }

    private static func parentDirectories(of path: String) -> [String] {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return [] }
        return (1..<components.count).map {
            components.prefix($0).joined(separator: "/")
        }
    }

    private static func relativePath(of url: URL, under directory: URL) throws -> String {
        let root = directory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else {
            throw NemotronLatin1120Error.invalidModelLayout(url.lastPathComponent)
        }
        return String(path.dropFirst(prefix.count))
    }
}
