import AudioToolbox
import AVFAudio
import Foundation

/// Borrows native PCM only after the complete declared layout is coherent.
/// The platform still owns the lifetime and allocation of each native pointer.
enum Downmix {
    /// Core Audio may retain byte counts while disabling a stream's data.
    /// This is unavailable input, not malformed PCM or digital silence.
    enum InputError: Error { case unavailable }

    struct Layout: Equatable {
        let frames: Int
        let channels: Int
        let planar: Bool
    }

    static func mono(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        try mono(fromBufferList: buffer.audioBufferList, format: buffer.format.streamDescription.pointee)
    }

    static func layout(
        of buffers: UnsafeMutableAudioBufferListPointer, format: AudioStreamBasicDescription
    ) throws -> Layout {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == kAudioFormatFlagsNativeEndian,
              format.mBitsPerChannel == 32,
              CapturePCMGeometry.isUsable(sampleRate: format.mSampleRate),
              format.mChannelsPerFrame > 0
        else { throw AudioCaptureError.unsupportedFormat }

        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = Int(format.mChannelsPerFrame)
        let channelsPerBuffer = planar ? 1 : channels
        let bytesPerFrame = channelsPerBuffer * MemoryLayout<Float>.size
        guard Int(format.mBytesPerFrame) == bytesPerFrame,
              buffers.count == (planar ? channels : 1),
              let first = buffers.first,
              Int(first.mDataByteSize).isMultiple(of: bytesPerFrame)
        else { throw AudioCaptureError.unsupportedFormat }

        // Validate every plane before reading the first sample. A short or
        // missing later plane must not overread, truncate, or become silence.
        for buffer in buffers {
            guard Int(buffer.mNumberChannels) == channelsPerBuffer,
                  buffer.mDataByteSize == first.mDataByteSize
            else { throw AudioCaptureError.unsupportedFormat }
        }
        if first.mDataByteSize > 0 {
            guard buffers.allSatisfy({ $0.mData != nil }) else { throw InputError.unavailable }
            for buffer in buffers {
                guard let data = buffer.mData,
                      UInt(bitPattern: data).isMultiple(of: UInt(MemoryLayout<Float>.alignment))
                else { throw AudioCaptureError.unsupportedFormat }
            }
        }
        return Layout(frames: Int(first.mDataByteSize) / bytesPerFrame, channels: channels, planar: planar)
    }

    static func mono(
        fromBufferList list: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription
    ) throws -> [Float] {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let layout = try layout(of: buffers, format: format)
        guard layout.frames > 0 else { return [] }
        if layout.channels == 1 {
            return Array(UnsafeBufferPointer(
                start: try samplePointer(buffers[0]), count: layout.frames))
        }
        if layout.planar { return try planarMono(buffers, layout: layout) }
        return try interleavedMono(buffers[0], layout: layout)
    }

    private static func samplePointer(_ buffer: AudioBuffer) throws -> UnsafePointer<Float> {
        guard let data = buffer.mData else { throw AudioCaptureError.unsupportedFormat }
        return UnsafePointer(data.assumingMemoryBound(to: Float.self))
    }

    private static func planarMono(_ buffers: UnsafeMutableAudioBufferListPointer, layout: Layout) throws -> [Float] {
        var output = [Float](repeating: 0, count: layout.frames)
        for buffer in buffers {
            let samples = try samplePointer(buffer)
            for frame in 0..<layout.frames { output[frame] += samples[frame] }
        }
        let scale = 1 / Float(layout.channels)
        for frame in 0..<layout.frames { output[frame] *= scale }
        return output
    }

    private static func interleavedMono(_ buffer: AudioBuffer, layout: Layout) throws -> [Float] {
        let samples = try samplePointer(buffer)
        var output = [Float](repeating: 0, count: layout.frames)
        for frame in 0..<layout.frames {
            var sum: Float = 0
            for channel in 0..<layout.channels { sum += samples[frame * layout.channels + channel] }
            output[frame] = sum / Float(layout.channels)
        }
        return output
    }
}
