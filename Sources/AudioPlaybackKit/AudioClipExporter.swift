import AVFoundation
import Foundation

/// Exports a time range of a meeting as a shareable audio clip (M11/D27).
/// Mixes the per-channel files into one m4a (AAC) — the same mix the player
/// hears — so a clip carries both you and the other participants.
public enum AudioClipExporter {
    public enum ClipError: Error, LocalizedError {
        case invalidRange
        case noAudio
        case exportFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidRange: return "El rango del clip no es válido."
            case .noAudio: return "La reunión no tiene audio para recortar."
            case .exportFailed(let reason): return "No se pudo exportar el clip: \(reason)"
            }
        }
    }

    /// Writes `[range]` of the mixed channels to `output` (AAC/m4a),
    /// overwriting any existing file. Cheap because it copies the trimmed
    /// range only — a 30 s clip is a fraction of a second on Apple Silicon.
    public static func export(
        channelFiles: [URL],
        range: ClosedRange<TimeInterval>,
        to output: URL
    ) async throws {
        let existing = channelFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { throw ClipError.noAudio }
        guard range.upperBound > range.lowerBound, range.lowerBound >= 0 else {
            throw ClipError.invalidRange
        }

        let composition = AVMutableComposition()
        let start = CMTime(seconds: range.lowerBound, preferredTimescale: 600)
        let requestedEnd = CMTime(seconds: range.upperBound, preferredTimescale: 600)
        for url in existing {
            let asset = AVURLAsset(url: url)
            guard
                let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                let duration = try? await asset.load(.duration),
                let track = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let end = CMTimeMinimum(requestedEnd, duration)
            guard end > start else { continue }
            try track.insertTimeRange(
                CMTimeRange(start: start, end: end), of: sourceTrack, at: .zero)
        }
        guard !composition.tracks(withMediaType: .audio).isEmpty else {
            throw ClipError.invalidRange
        }

        try? FileManager.default.removeItem(at: output)
        guard
            let session = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetAppleM4A)
        else { throw ClipError.exportFailed("no export session") }

        if #available(macOS 15.0, iOS 18.0, *) {
            try await session.export(to: output, as: .m4a)
        } else {
            session.outputURL = output
            session.outputFileType = .m4a
            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
            guard session.status == .completed else {
                throw ClipError.exportFailed(session.error?.localizedDescription ?? "unknown")
            }
        }
    }
}
