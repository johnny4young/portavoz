import AVFAudio
import Foundation
import PortavozCore

/// Writes one audio channel to a 16-bit PCM WAV file, converting from the
/// pipeline's Float32 mono chunks. Native AVAudioFile — no external encoder.
///
/// `@unchecked Sendable`: writes are serialized by the owning channel task.
public final class WAVWriter: @unchecked Sendable {
    public let url: URL
    private let file: AVAudioFile
    private let bufferFormat: AVAudioFormat
    public private(set) var framesWritten: AVAudioFramePosition = 0

    public init(url: URL, sampleRate: Double) throws {
        self.url = url
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
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
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: bufferFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channelData = buffer.floatChannelData else {
            throw AudioCaptureError.unsupportedFormat
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            channelData[0].update(from: pointer.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
        framesWritten += AVAudioFramePosition(samples.count)
    }

    public var secondsWritten: TimeInterval {
        Double(framesWritten) / file.fileFormat.sampleRate
    }
}
