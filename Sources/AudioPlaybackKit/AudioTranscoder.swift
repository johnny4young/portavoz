import AVFoundation
import Foundation

/// Transcodes a meeting's raw audio to AAC/m4a (M11/D27, GAPS T6). Capture
/// keeps lossless CAF/WAV (~126 MB per channel for 22 min); once the
/// transcript is what matters, AAC drops that to a few MB with no audible
/// loss for speech.
public enum AudioTranscoder {
    typealias AACEncoder = @Sendable (_ source: URL, _ output: URL) async throws -> Void

    public enum TranscodeError: Error, LocalizedError {
        case exportFailed(String)
        case outputAlreadyExists(String)

        public var errorDescription: String? {
            switch self {
            case .exportFailed(let reason): return "Could not compress audio: \(reason)"
            case .outputAlreadyExists(let filename):
                return "Could not compress audio because \(filename) already exists."
            }
        }
    }

    /// Transcodes `source` to an `.m4a` next to it and returns the new URL.
    /// With `deleteSource`, the original is removed ONLY after the m4a is
    /// verified on disk — a failure never loses the recording.
    @discardableResult
    public static func toAAC(source: URL, deleteSource: Bool = true) async throws -> URL {
        if source.pathExtension.lowercased() == "m4a" { return source }
        let output = source.deletingPathExtension().appendingPathExtension("m4a")
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw TranscodeError.outputAlreadyExists(output.lastPathComponent)
        }

        do {
            try await encodeAAC(source: source, output: output)
            try verifyAudio(at: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        if deleteSource { try? FileManager.default.removeItem(at: source) }
        return output
    }

    /// Transcodes every raw channel as one failure-safe batch. Originals remain in
    /// place until every canonical AAC output is verified. A failure or
    /// cancellation removes this attempt's outputs and leaves every original
    /// usable.
    public static func toAAC(
        sources: [URL],
        deleteSources: Bool = true
    ) async throws -> [URL] {
        try await toAAC(
            sources: sources,
            deleteSources: deleteSources,
            encoder: encodeAAC)
    }

    static func toAAC(
        sources: [URL],
        deleteSources: Bool = true,
        encoder: AACEncoder
    ) async throws -> [URL] {
        guard !sources.isEmpty else { return [] }
        let rawSources = sources.filter { $0.pathExtension.lowercased() != "m4a" }
        guard !rawSources.isEmpty else { return sources }

        let outputs = rawSources.map {
            $0.deletingPathExtension().appendingPathExtension("m4a")
        }
        guard Set(outputs.map(\.standardizedFileURL)).count == outputs.count else {
            throw TranscodeError.exportFailed("multiple channels resolve to the same output")
        }
        if let existing = outputs.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            throw TranscodeError.outputAlreadyExists(existing.lastPathComponent)
        }

        let parentDirectories = Set(outputs.map {
            $0.deletingLastPathComponent().standardizedFileURL
        })
        guard parentDirectories.count == 1 else {
            throw TranscodeError.exportFailed("meeting channels are not colocated")
        }

        do {
            for index in rawSources.indices {
                try Task.checkCancellation()
                try await encoder(rawSources[index], outputs[index])
                try verifyAudio(at: outputs[index])
            }
            try Task.checkCancellation()
        } catch {
            for output in outputs {
                try? FileManager.default.removeItem(at: output)
            }
            throw error
        }

        if deleteSources {
            for source in rawSources {
                try? FileManager.default.removeItem(at: source)
            }
        }

        let replacements = Dictionary(
            uniqueKeysWithValues: zip(rawSources, outputs).map {
                ($0.standardizedFileURL, $1)
            })
        return sources.map { source in
            replacements[source.standardizedFileURL] ?? source
        }
    }

    private static func encodeAAC(source: URL, output: URL) async throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw TranscodeError.exportFailed("source audio is missing")
        }
        let asset = AVURLAsset(url: source)
        guard
            let session = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetAppleM4A)
        else { throw TranscodeError.exportFailed("no export session") }

        if #available(macOS 15.0, iOS 18.0, *) {
            try await session.export(to: output, as: .m4a)
        } else {
            session.outputURL = output
            session.outputFileType = .m4a
            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
            guard session.status == .completed else {
                throw TranscodeError.exportFailed(
                    session.error?.localizedDescription ?? "unknown")
            }
        }
    }

    private static func verifyAudio(at output: URL) throws {
        let values = try output.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize > 0 else {
            throw TranscodeError.exportFailed("output is empty")
        }
        guard let file = try? AVAudioFile(forReading: output), file.length > 0 else {
            throw TranscodeError.exportFailed("output is not readable audio")
        }
    }

    /// Bytes on disk for a set of files (missing ones count as 0).
    public static func totalBytes(of urls: [URL]) -> Int64 {
        urls.reduce(0) { sum, url in
            // URL resource values may retain a file-size cache after this
            // exact URL was deleted during compression. Query the filesystem
            // so before/after accounting reflects what is actually on disk.
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return sum + size
        }
    }
}
