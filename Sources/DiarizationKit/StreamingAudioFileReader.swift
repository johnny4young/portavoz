import AVFoundation
import Foundation
import PortavozCore

/// Streams mono 16 kHz Float32 audio from disk in bounded chunks so batch
/// diarization and voiceprint extraction stay O(window) in RAM instead of
/// decoding an entire multi-hour recording into one array.
enum StreamingAudioFileReader {
    enum ReaderError: Error, Sendable {
        case unreadableFormat
    }

    private static let readBlockFrames: AVAudioFrameCount = 48_000

    static func streamMonoWindows(
        url: URL,
        targetSampleRate: Int,
        windowSeconds: TimeInterval,
        onWindow: (_ samples: [Float], _ offset: TimeInterval) throws -> Void
    ) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let sourceRate = file.processingFormat.sampleRate
        let channelCount = Int(file.processingFormat.channelCount)
        guard sourceRate.isFinite, sourceRate > 0, channelCount > 0 else {
            throw ReaderError.unreadableFormat
        }
        let targetRate = Double(targetSampleRate)
        let windowSampleCount = max(1, Int((windowSeconds * targetRate).rounded()))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: readBlockFrames)
        else {
            throw ReaderError.unreadableFormat
        }

        var resampler = StreamingLinearResampler()
        var pending: [Float] = []
        pending.reserveCapacity(windowSampleCount + Int(readBlockFrames))
        var emittedSamples: Int64 = 0
        var totalSourceFrames: AVAudioFramePosition = 0

        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let framesToRead = AVAudioFrameCount(min(AVAudioFramePosition(readBlockFrames), remaining))
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: framesToRead)
            let readCount = Int(buffer.frameLength)
            guard readCount > 0 else { break }
            totalSourceFrames += AVAudioFramePosition(readCount)

            let mono = downmixMono(buffer: buffer, frameCount: readCount, channelCount: channelCount)
            let resampled = try resample(mono, from: sourceRate, to: targetRate, using: &resampler)
            pending.append(contentsOf: resampled)

            while pending.count >= windowSampleCount {
                let offset = Double(emittedSamples) / targetRate
                let window = Array(pending.prefix(windowSampleCount))
                pending.removeFirst(windowSampleCount)
                emittedSamples += Int64(window.count)
                try onWindow(window, offset)
            }
        }

        if !pending.isEmpty {
            let offset = Double(emittedSamples) / targetRate
            try onWindow(pending, offset)
        }
        return Double(totalSourceFrames) / sourceRate
    }

    static func extractMonoRanges(
        url: URL,
        ranges: [ClosedRange<TimeInterval>],
        targetSampleRate: Int,
        maximumSeconds: TimeInterval
    ) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceRate = file.processingFormat.sampleRate
        let channelCount = Int(file.processingFormat.channelCount)
        guard sourceRate.isFinite, sourceRate > 0, channelCount > 0 else {
            throw ReaderError.unreadableFormat
        }
        let targetRate = Double(targetSampleRate)
        let maximumSamples = max(0, Int((maximumSeconds * targetRate).rounded()))
        guard maximumSamples > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: readBlockFrames)
        else {
            throw ReaderError.unreadableFormat
        }

        let sortedRanges = ranges.sorted {
            ($0.upperBound - $0.lowerBound) > ($1.upperBound - $1.lowerBound)
        }
        var gathered: [Float] = []
        gathered.reserveCapacity(maximumSamples)

        for range in sortedRanges {
            guard gathered.count < maximumSamples else { break }
            let startFrame = max(0, AVAudioFramePosition((range.lowerBound * sourceRate).rounded(.down)))
            let endFrame = min(file.length, AVAudioFramePosition((range.upperBound * sourceRate).rounded(.up)))
            guard endFrame > startFrame else { continue }

            file.framePosition = startFrame
            var resampler = StreamingLinearResampler()
            var remaining = endFrame - startFrame

            while remaining > 0, gathered.count < maximumSamples {
                let framesToRead = AVAudioFrameCount(min(AVAudioFramePosition(readBlockFrames), remaining))
                buffer.frameLength = 0
                try file.read(into: buffer, frameCount: framesToRead)
                let readCount = Int(buffer.frameLength)
                guard readCount > 0 else { break }
                remaining -= AVAudioFramePosition(readCount)

                let mono = downmixMono(buffer: buffer, frameCount: readCount, channelCount: channelCount)
                let resampled = try resample(mono, from: sourceRate, to: targetRate, using: &resampler)
                let needed = maximumSamples - gathered.count
                if resampled.count <= needed {
                    gathered.append(contentsOf: resampled)
                } else {
                    gathered.append(contentsOf: resampled.prefix(needed))
                }
            }
        }
        return gathered
    }

    private static func downmixMono(
        buffer: AVAudioPCMBuffer,
        frameCount: Int,
        channelCount: Int
    ) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frameCount))
        }
        var mono = [Float](repeating: 0, count: frameCount)
        let scale = 1.0 / Float(channelCount)
        for ch in 0..<channelCount {
            let src = channels[ch]
            for frame in 0..<frameCount {
                mono[frame] += src[frame] * scale
            }
        }
        return mono
    }

    private static func resample(
        _ mono: [Float],
        from sourceRate: Double,
        to targetRate: Double,
        using resampler: inout StreamingLinearResampler
    ) throws -> [Float] {
        guard sourceRate != targetRate else { return mono }
        let maxOut = Int((Double(mono.count) * targetRate / sourceRate).rounded(.up)) + 4
        return try resampler.resample(
            mono,
            from: sourceRate,
            to: targetRate,
            maximumOutputSamples: maxOut)
    }
}
