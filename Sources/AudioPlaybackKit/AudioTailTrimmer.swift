import AVFoundation
import Foundation

public enum AudioTailTrimmerError: Error, Equatable {
    case unsupportedFormat(String)
    case verificationFailed(String)
}

/// Cuts channel files at a point in time. Copies are written and verified
/// beside the originals under names the channel layout never resolves, and
/// replace them only as one batch.
public enum AudioTailTrimmer {
    /// Writes each file cut at `cutoff` seconds and returns the verified copies
    /// in the same order. Nothing is left behind on failure or cancellation.
    public static func stage(_ files: [URL], cutoff: TimeInterval) async throws -> [URL] {
        var staged: [URL] = []
        do {
            for file in files {
                try Task.checkCancellation()
                let copy = file.deletingLastPathComponent().appendingPathComponent(
                    "\(file.deletingPathExtension().lastPathComponent).trim-\(UUID().uuidString)"
                        + ".\(file.pathExtension)")
                staged.append(copy)
                switch file.pathExtension.lowercased() {
                case "caf", "wav", "aif", "aiff":
                    try copyFrames(from: file, to: copy, cutoff: cutoff)
                case "m4a":
                    try await exportPassthrough(from: file, to: copy, cutoff: cutoff)
                default:
                    throw AudioTailTrimmerError.unsupportedFormat(file.pathExtension)
                }
                try verify(copy, expectedDuration: min(cutoff, duration(of: file)))
            }
            return staged
        } catch {
            discard(staged)
            throw error
        }
    }

    /// Swaps every original for its copy, restoring the originals if any swap fails.
    public static func commit(originals: [URL], staged: [URL]) throws {
        precondition(originals.count == staged.count)
        let manager = FileManager.default
        var backups: [(original: URL, backup: URL)] = []
        do {
            for (original, copy) in zip(originals, staged) {
                let backup = original.deletingLastPathComponent().appendingPathComponent(
                    "\(original.lastPathComponent).trim-backup-\(UUID().uuidString)")
                try manager.copyItem(at: original, to: backup)
                backups.append((original, backup))
                _ = try manager.replaceItemAt(original, withItemAt: copy)
            }
        } catch {
            for (original, backup) in backups {
                _ = try? manager.replaceItemAt(original, withItemAt: backup)
            }
            discard(staged + backups.map(\.backup))
            throw error
        }
        discard(backups.map(\.backup))
    }

    public static func discard(_ files: [URL]) {
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    private static func copyFrames(from source: URL, to destination: URL, cutoff: TimeInterval) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let output = try AVAudioFile(
            forWriting: destination,
            settings: input.fileFormat.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved)
        var remaining = min(input.length, AVAudioFramePosition(cutoff * format.sampleRate))
        let capacity: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AudioTailTrimmerError.unsupportedFormat(source.pathExtension)
        }
        while remaining > 0 {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, Int64(capacity))))
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }

    private static func exportPassthrough(from source: URL, to destination: URL, cutoff: TimeInterval) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw AudioTailTrimmerError.unsupportedFormat(source.pathExtension)
        }
        session.timeRange = CMTimeRange(
            start: .zero, duration: CMTime(seconds: cutoff, preferredTimescale: 600))
        try await session.export(to: destination, as: .m4a)
    }

    private static func duration(of file: URL) -> TimeInterval {
        guard let audio = try? AVAudioFile(forReading: file) else { return .infinity }
        return Double(audio.length) / audio.processingFormat.sampleRate
    }

    private static func verify(_ file: URL, expectedDuration: TimeInterval) throws {
        let actual = duration(of: file)
        guard actual.isFinite, actual > 0, abs(actual - expectedDuration) <= 0.5 else {
            throw AudioTailTrimmerError.verificationFailed(file.lastPathComponent)
        }
    }
}
