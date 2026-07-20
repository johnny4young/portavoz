import AVFAudio
import CryptoKit
import Foundation
import PortavozCore

/// Immutable evidence produced only after a crash-readable capture file has
/// been inspected. Reader-visible files are either atomically published by
/// this module or revalidated after a crash between rename and DB commit.
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

/// Public filesystem recovery boundary. It derives signal evidence from the
/// persisted PCM itself because in-memory capture meters disappear on crash.
public enum CaptureFileRecovery {
    public static func publish(
        stagingURL: URL,
        finalURL: URL
    ) throws -> PublishedCaptureFile {
        try CaptureFilePublication.requireAtomicMove(
            stagingURL: stagingURL, finalURL: finalURL)
        let evidence = try CaptureFileEvidence.inspect(stagingURL, signal: nil)
        guard !FileManager.default.fileExists(atPath: finalURL.path) else {
            throw AudioCaptureError.captureDestinationExists(finalURL.path)
        }
        try FileManager.default.moveItem(at: stagingURL, to: finalURL)
        return evidence.published(at: finalURL)
    }

    /// Handles a crash after the atomic rename but before the captured DB
    /// transaction: the final file is never trusted merely because it exists.
    public static func inspectPublishedFile(
        at url: URL
    ) throws -> PublishedCaptureFile {
        try CaptureFileEvidence.inspect(url, signal: nil).published(at: url)
    }
}

/// Normal Stop path: reuse meters accumulated only after successful writes,
/// avoiding a second full read of a meeting-length file.
enum CaptureFilePublisher {
    static func publish(
        stagingURL: URL,
        finalURL: URL,
        peak: Float,
        rms: Float
    ) throws -> PublishedCaptureFile {
        try CaptureFilePublication.requireAtomicMove(
            stagingURL: stagingURL, finalURL: finalURL)
        guard peak.isFinite, rms.isFinite, peak >= 0, rms >= 0 else {
            throw AudioCaptureError.invalidCaptureFile(stagingURL.path)
        }
        let evidence = try CaptureFileEvidence.inspect(
            stagingURL, signal: (peak: peak, rms: rms))
        guard !FileManager.default.fileExists(atPath: finalURL.path) else {
            throw AudioCaptureError.captureDestinationExists(finalURL.path)
        }
        try FileManager.default.moveItem(at: stagingURL, to: finalURL)
        return evidence.published(at: finalURL)
    }
}

private enum CaptureFilePublication {
    static func requireAtomicMove(stagingURL: URL, finalURL: URL) throws {
        let stagingDirectory = stagingURL.deletingLastPathComponent().standardizedFileURL
        let finalDirectory = finalURL.deletingLastPathComponent().standardizedFileURL
        guard stagingDirectory == finalDirectory,
            stagingURL.standardizedFileURL != finalURL.standardizedFileURL
        else {
            throw AudioCaptureError.nonAtomicCapturePublication(finalURL.path)
        }
    }
}

private struct CaptureFileEvidence {
    let sampleRate: Double
    let channelCount: Int
    let durationSeconds: TimeInterval
    let byteCount: Int64
    let sha256: String
    let healthStatus: AudioAssetHealthStatus
    let peakDBFS: Double
    let rmsDBFS: Double

    static func inspect(
        _ url: URL,
        signal suppliedSignal: (peak: Float, rms: Float)?
    ) throws -> CaptureFileEvidence {
        let media = try inspectMedia(url)
        let signal = try suppliedSignal ?? measureSignal(url)
        let byteCount = try fileSize(url)
        let checksum = try sha256(of: url)
        let health: AudioAssetHealthStatus
        if signal.peak == 0 {
            health = .silent
        } else if signal.peak >= 0.999 {
            health = .clipped
        } else {
            health = .healthy
        }
        return CaptureFileEvidence(
            sampleRate: media.sampleRate,
            channelCount: media.channelCount,
            durationSeconds: media.duration,
            byteCount: byteCount,
            sha256: checksum,
            healthStatus: health,
            peakDBFS: decibels(for: signal.peak),
            rmsDBFS: decibels(for: signal.rms))
    }

    func published(at url: URL) -> PublishedCaptureFile {
        PublishedCaptureFile(
            url: url,
            container: "caf",
            codec: "pcm-s16le",
            sampleRate: sampleRate,
            channelCount: channelCount,
            durationSeconds: durationSeconds,
            byteCount: byteCount,
            sha256: sha256,
            healthStatus: healthStatus,
            peakDBFS: peakDBFS,
            rmsDBFS: rmsDBFS)
    }

    private static func inspectMedia(
        _ url: URL
    ) throws -> (sampleRate: Double, channelCount: Int, duration: TimeInterval) {
        try autoreleasepool {
            guard url.pathExtension.lowercased() == "caf" else {
                throw AudioCaptureError.invalidCaptureFile(url.path)
            }
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.fileFormat.sampleRate
            let channels = Int(file.fileFormat.channelCount)
            let frames = file.length
            guard file.fileFormat.commonFormat == .pcmFormatInt16,
                sampleRate.isFinite,
                sampleRate > 0,
                channels == 1,
                frames > 0
            else {
                throw AudioCaptureError.invalidCaptureFile(url.path)
            }
            return (sampleRate, channels, Double(frames) / sampleRate)
        }
    }

    private static func measureSignal(_ url: URL) throws -> (peak: Float, rms: Float) {
        try autoreleasepool {
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: 8_192)
            else { throw AudioCaptureError.invalidCaptureFile(url.path) }
            var peak: Float = 0
            var sumSquares = 0.0
            var sampleCount: Int64 = 0
            while file.framePosition < file.length {
                try file.read(into: buffer)
                let frames = Int(buffer.frameLength)
                guard frames > 0, let samples = buffer.floatChannelData?[0] else { break }
                for index in 0..<frames {
                    let magnitude = min(abs(samples[index]), 1)
                    peak = max(peak, magnitude)
                    sumSquares += Double(magnitude) * Double(magnitude)
                }
                sampleCount += Int64(frames)
            }
            guard sampleCount > 0 else {
                throw AudioCaptureError.invalidCaptureFile(url.path)
            }
            return (peak, Float((sumSquares / Double(sampleCount)).squareRoot()))
        }
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw AudioCaptureError.invalidCaptureFile(url.path)
        }
        return Int64(size)
    }

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

    private static func decibels(for amplitude: Float) -> Double {
        20 * log10(max(Double(amplitude), 1e-8))
    }
}
