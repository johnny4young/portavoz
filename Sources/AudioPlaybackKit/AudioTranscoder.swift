import AVFoundation
import Foundation

/// Transcodes a meeting's raw audio to AAC/m4a (M11/D27, GAPS T6). Capture
/// keeps lossless CAF/WAV (~126 MB per channel for 22 min); once the
/// transcript is what matters, AAC drops that to a few MB with no audible
/// loss for speech.
public enum AudioTranscoder {
    public enum TranscodeError: Error, LocalizedError {
        case exportFailed(String)

        public var errorDescription: String? {
            switch self {
            case .exportFailed(let reason): return "No se pudo comprimir el audio: \(reason)"
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
        try? FileManager.default.removeItem(at: output)

        let asset = AVURLAsset(url: source)
        guard
            let session = AVAssetExportSession(
                asset: asset, presetName: AVAssetExportPresetAppleM4A)
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
                throw TranscodeError.exportFailed(session.error?.localizedDescription ?? "unknown")
            }
        }

        guard FileManager.default.fileExists(atPath: output.path) else {
            throw TranscodeError.exportFailed("output missing")
        }
        if deleteSource { try? FileManager.default.removeItem(at: source) }
        return output
    }

    /// Bytes on disk for a set of files (missing ones count as 0).
    public static func totalBytes(of urls: [URL]) -> Int64 {
        urls.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return sum + Int64(size)
        }
    }
}
