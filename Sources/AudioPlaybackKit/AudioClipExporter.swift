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
            case .invalidRange: return "The clip range is invalid."
            case .noAudio: return "The meeting has no audio to trim."
            case .exportFailed(let reason): return "Could not export the clip: \(reason)"
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

    /// Clear-channel export matching the default player. The complete
    /// composition is built once, then AVFoundation trims the requested
    /// timeline range during export.
    public static func export(
        systemFile: URL?,
        microphoneFile: URL?,
        microphoneAudibleRanges: [ClosedRange<TimeInterval>],
        clearPlayback: Bool,
        range: ClosedRange<TimeInterval>,
        to output: URL
    ) async throws {
        guard range.upperBound > range.lowerBound, range.lowerBound >= 0 else {
            throw ClipError.invalidRange
        }
        guard let mixed = await MeetingAudioComposition.make(
            systemFile: systemFile,
            microphoneFile: microphoneFile,
            microphoneAudibleRanges: microphoneAudibleRanges)
        else { throw ClipError.noAudio }
        let start = CMTime(seconds: range.lowerBound, preferredTimescale: 600)
        let end = CMTimeMinimum(
            CMTime(seconds: range.upperBound, preferredTimescale: 600),
            mixed.duration)
        guard end > start else { throw ClipError.invalidRange }

        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(
            asset: mixed.composition,
            presetName: AVAssetExportPresetAppleM4A)
        else { throw ClipError.exportFailed("no export session") }
        session.timeRange = CMTimeRange(start: start, end: end)
        if clearPlayback {
            session.audioMix = mixed.cleanAudioMix
        }

        if #available(macOS 15.0, iOS 18.0, *) {
            try await session.export(to: output, as: .m4a)
        } else {
            session.outputURL = output
            session.outputFileType = .m4a
            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
            guard session.status == .completed else {
                throw ClipError.exportFailed(
                    session.error?.localizedDescription ?? "unknown")
            }
        }
    }
}
