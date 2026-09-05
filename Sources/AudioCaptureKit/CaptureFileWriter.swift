import AVFAudio
import Foundation
import PortavozCore

/// Writes one audio channel as 16-bit PCM, converting from the pipeline's
/// Float32 mono chunks. Native AVAudioFile — no external encoder. The
/// container comes from the URL extension: capture uses **CAF**, whose
/// data chunk is sized "to EOF" while being written — a crash mid-meeting
/// leaves a fully readable file (a killed WAV reads as 0 bytes of audio;
/// verified empirically with kill -9).
///
/// `@unchecked Sendable`: writes are serialized by the owning channel task.
public final class CaptureFileWriter: @unchecked Sendable {
    public let url: URL
    private var file: AVAudioFile?
    private let bufferFormat: AVAudioFormat
    private let sampleRate: Double
    private var reusableBuffer: AVAudioPCMBuffer?
    public private(set) var framesWritten: AVAudioFramePosition = 0

    public init(url: URL, sampleRate: Double) throws {
        self.url = url
        self.sampleRate = sampleRate
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.unsupportedFormat
        }
        self.bufferFormat = format
        self.file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    public func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        guard let file else { throw AudioCaptureError.captureWriterClosed }
        let requiredCapacity = AVAudioFrameCount(samples.count)
        let buffer: AVAudioPCMBuffer
        if let reusableBuffer, reusableBuffer.frameCapacity >= requiredCapacity {
            buffer = reusableBuffer
        } else {
            guard let created = AVAudioPCMBuffer(
                pcmFormat: bufferFormat,
                frameCapacity: requiredCapacity
            ) else { throw AudioCaptureError.unsupportedFormat }
            reusableBuffer = created
            buffer = created
        }
        guard let channelData = buffer.floatChannelData else {
            throw AudioCaptureError.unsupportedFormat
        }
        buffer.frameLength = requiredCapacity
        samples.withUnsafeBufferPointer { pointer in
            channelData[0].update(from: pointer.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
        framesWritten += AVAudioFramePosition(samples.count)
    }

    public var secondsWritten: TimeInterval {
        Double(framesWritten) / sampleRate
    }

    /// Ends the native file lifetime before validation/publication. Stop must
    /// not depend on when a completed Swift Task releases its captured writer.
    func close() {
        reusableBuffer = nil
        file = nil
    }
}
