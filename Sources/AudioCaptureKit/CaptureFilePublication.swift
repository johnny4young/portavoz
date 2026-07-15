import AVFAudio
import CryptoKit
import Foundation
import PortavozCore

/// Immutable evidence produced only after a crash-readable staging file has
/// been inspected and atomically published under its reader-visible name.
public struct PublishedCaptureFile: Sendable {
    public let url: URL
    public let container: String
    public let codec: String
    public let sampleRate: Double
    public let channelCount: Int
    public let durationSeconds: TimeInterval
    public let byteCount: Int64
    public let sha256: String
    public let healthStatus: AudioAssetHealthStatus
    public let peakDBFS: Double
    public let rmsDBFS: Double
}

/// Filesystem half of the capture saga. A valid staging CAF is inspected and
/// hashed before one same-directory rename publishes it. Existing final files
/// are never overwritten: a collision needs recovery, not data destruction.
enum CaptureFilePublisher {
    static func publish(
        stagingURL: URL,
        finalURL: URL,
        peak: Float,
        rms: Float
    ) throws -> PublishedCaptureFile {
        let stagingDirectory = stagingURL.deletingLastPathComponent().standardizedFileURL
        let finalDirectory = finalURL.deletingLastPathComponent().standardizedFileURL
        guard stagingDirectory == finalDirectory else {
            throw AudioCaptureError.nonAtomicCapturePublication(finalURL.path)
        }
        guard stagingURL.standardizedFileURL != finalURL.standardizedFileURL else {
            throw AudioCaptureError.nonAtomicCapturePublication(finalURL.path)
        }
        guard peak.isFinite, rms.isFinite, peak >= 0, rms >= 0 else {
            throw AudioCaptureError.invalidCaptureFile(stagingURL.path)
        }

        let media = try inspect(stagingURL)
        let byteCount = try fileSize(stagingURL)
        let checksum = try sha256(of: stagingURL)
        guard !FileManager.default.fileExists(atPath: finalURL.path) else {
            throw AudioCaptureError.captureDestinationExists(finalURL.path)
        }

        // `moveItem` is a single rename because both URLs are in the same
        // directory. Readers can observe either staging or final, never half.
        try FileManager.default.moveItem(at: stagingURL, to: finalURL)

        let health: AudioAssetHealthStatus
        if peak == 0 {
            health = .silent
        } else if peak >= 0.999 {
            health = .clipped
        } else {
            health = .healthy
        }
        return PublishedCaptureFile(
            url: finalURL,
            container: "caf",
            codec: "pcm-s16le",
            sampleRate: media.sampleRate,
            channelCount: media.channelCount,
            durationSeconds: media.duration,
            byteCount: byteCount,
            sha256: checksum,
            healthStatus: health,
            peakDBFS: decibels(for: peak),
            rmsDBFS: decibels(for: rms))
    }

    private static func inspect(
        _ url: URL
    ) throws -> (sampleRate: Double, channelCount: Int, duration: TimeInterval) {
        try autoreleasepool {
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.fileFormat.sampleRate
            let channels = Int(file.fileFormat.channelCount)
            let frames = file.length
            guard sampleRate.isFinite, sampleRate > 0, channels == 1, frames > 0 else {
                throw AudioCaptureError.invalidCaptureFile(url.path)
            }
            return (sampleRate, channels, Double(frames) / sampleRate)
        }
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw AudioCaptureError.invalidCaptureFile(url.path)
        }
        return Int64(size)
    }

    /// Streaming SHA-256 keeps meeting-length PCM files out of memory.
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Digital silence uses a finite floor so SQLite never receives `-inf`.
    private static func decibels(for amplitude: Float) -> Double {
        20 * log10(max(Double(amplitude), 1e-8))
    }
}
