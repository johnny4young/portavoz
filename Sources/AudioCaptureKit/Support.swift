import AVFAudio
import CoreAudioTypes
import Foundation

public enum AudioCaptureError: Error, Sendable {
    case noInputDevice
    case coreAudioError(operation: String, status: Int32)
    case processNotFound(Int32)
    case unsupportedFormat
}

/// Converts Core Audio host times into seconds elapsed since the first
/// callback of a session.
///
/// `@unchecked Sendable`: `start` is written exactly once, from the
/// serialized audio callback path that owns this clock.
final class HostClock: @unchecked Sendable {
    private var start: UInt64 = 0

    func elapsed(hostTime: UInt64) -> TimeInterval {
        if start == 0 { start = hostTime }
        return AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: start)
    }
}

enum Downmix {
    /// Averages all channels of a PCM buffer into mono.
    static func mono(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return [] }
        let channels = Int(buffer.format.channelCount)
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: data[0], count: frames))
        }
        var out = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            let pointer = data[channel]
            for frame in 0..<frames { out[frame] += pointer[frame] }
        }
        let scale = 1 / Float(channels)
        for frame in 0..<frames { out[frame] *= scale }
        return out
    }

    /// Averages a Float32 Core Audio buffer list (planar or interleaved) into mono.
    static func mono(
        fromBufferList list: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription
    ) -> [Float] {
        guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return [] }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))

        if format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            let channels = buffers.count
            guard let first = buffers.first, first.mData != nil, channels > 0 else { return [] }
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return [] }
            var out = [Float](repeating: 0, count: frames)
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let pointer = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames { out[frame] += pointer[frame] }
            }
            let scale = 1 / Float(channels)
            for frame in 0..<frames { out[frame] *= scale }
            return out
        }

        guard let buffer = buffers.first, let data = buffer.mData else { return [] }
        let channels = Int(buffer.mNumberChannels)
        guard channels > 0 else { return [] }
        let totalValues = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let frames = totalValues / channels
        let pointer = data.assumingMemoryBound(to: Float.self)
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: pointer, count: frames))
        }
        var out = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var acc: Float = 0
            for channel in 0..<channels { acc += pointer[frame * channels + channel] }
            out[frame] = acc / Float(channels)
        }
        return out
    }
}
