import AudioToolbox
import AVFAudio
import Foundation
import XCTest
@testable import AudioCaptureKit

final class DownmixLayoutTests: XCTestCase {
    func testNativePlanarAndInterleavedMatrixPreservesFramesAndChannelAverages() throws {
        for rate in [16_000.0, 48_000] {
            for channels: AVAudioChannelCount in [1, 2, 3, 6, 8] {
                for frames: AVAudioFrameCount in [0, 1, 2, 17] {
                    for interleaved in [false, true] {
                        let buffer = try makeBuffer(channels: channels, frames: frames,
                                                    interleaved: interleaved, rate: rate)
                        let data = try XCTUnwrap(buffer.floatChannelData)
                        var expected: [Float] = []
                        for frame in 0..<Int(frames) {
                            var sum: Float = 0
                            for channel in 0..<Int(channels) {
                                let sample = Float((frame * 11 + channel * 7) % 19 - 9) / 10
                                data[channel][frame * buffer.stride] = sample
                                sum += sample
                            }
                            expected.append(interleaved ? sum / Float(channels) : sum * (1 / Float(channels)))
                        }
                        XCTAssertEqual(try Downmix.mono(from: buffer), expected)
                        XCTAssertEqual(try Downmix.mono(fromBufferList: buffer.audioBufferList,
                            format: buffer.format.streamDescription.pointee), expected)
                    }
                }
            }
        }
    }

    func testInterleavedAudioUsesFrameStrideRatherThanAdjacentChannelValues() throws {
        let buffer = try makeBuffer(channels: 2, frames: 4, interleaved: true)
        let data = try XCTUnwrap(buffer.floatChannelData)
        let left: [Float] = [1, 0.5, -0.5, -1]
        let right: [Float] = [0, 1, 1, 0]
        for frame in 0..<4 {
            data[0][frame * buffer.stride] = left[frame]
            data[1][frame * buffer.stride] = right[frame]
        }
        XCTAssertEqual(try Downmix.mono(from: buffer), [0.5, 0.75, 0.25, -0.5])
    }

    func testShorterLaterPlaneRejectsBeforeReadingOrTruncatingAnyChannel() throws {
        let buffer = try makeBuffer(channels: 2, frames: 4, interleaved: false)
        try withListCopy(buffer) { list in
            list[1].mDataByteSize = 4
            assertUnsupported(try Downmix.mono(fromBufferList: list.unsafePointer,
                format: buffer.format.streamDescription.pointee))
        }
    }

    func testDisabledNonemptyPlaneIsUnavailableRatherThanAttenuatingItsPeer() throws {
        let buffer = try makeBuffer(channels: 2, frames: 4, interleaved: false)
        try withListCopy(buffer) { list in
            list[1].mData = nil
            XCTAssertThrowsError(try Downmix.mono(fromBufferList: list.unsafePointer,
                format: buffer.format.streamDescription.pointee)) { error in
                guard case Downmix.InputError.unavailable = error else {
                    return XCTFail("disabled data must stay recoverable, got \(error)")
                }
            }
        }
    }

    func testDisabledInputCanReturnWithItsOriginalCompleteFrameSet() throws {
        let buffer = try makeBuffer(channels: 2, frames: 4, interleaved: true)
        let data = try XCTUnwrap(buffer.floatChannelData)
        data[0].update(repeating: 0.5, count: 8)
        try withListCopy(buffer) { list in
            let original = list[0].mData
            list[0].mData = nil
            XCTAssertThrowsError(try Downmix.mono(fromBufferList: list.unsafePointer,
                format: buffer.format.streamDescription.pointee)) { error in
                guard case Downmix.InputError.unavailable = error else {
                    return XCTFail("disabled input is not a permanent format failure")
                }
            }
            list[0].mData = original
            XCTAssertEqual(try Downmix.mono(fromBufferList: list.unsafePointer,
                format: buffer.format.streamDescription.pointee), [Float](repeating: 0.5, count: 4))
        }
    }

    func testPartialFramesRejectInBothLayouts() throws {
        for interleaved in [false, true] {
            let buffer = try makeBuffer(channels: 2, frames: 4, interleaved: interleaved)
            try withListCopy(buffer) { list in
                for index in list.indices { list[index].mDataByteSize -= 1 }
                assertUnsupported(try Downmix.mono(fromBufferList: list.unsafePointer,
                    format: buffer.format.streamDescription.pointee))
            }
        }
    }

    func testChannelLayoutMismatchRejectsWithoutReinterpretingBuffers() throws {
        for interleaved in [false, true] {
            let buffer = try makeBuffer(channels: 2, frames: 4, interleaved: interleaved)
            try withListCopy(buffer) { list in
                list[0].mNumberChannels = interleaved ? 1 : 2
                assertUnsupported(try Downmix.mono(fromBufferList: list.unsafePointer,
                    format: buffer.format.streamDescription.pointee))
            }
        }
        let buffer = try makeBuffer(channels: 2, frames: 4, interleaved: false)
        try withListCopy(buffer) { list in
            list.unsafeMutablePointer.pointee.mNumberBuffers = 1
            assertUnsupported(try Downmix.mono(fromBufferList: list.unsafePointer,
                format: buffer.format.streamDescription.pointee))
        }
    }

    func testUnsupportedFormatGeometryRejectsBeforeBorrowingPCM() throws {
        let buffer = try makeBuffer(channels: 2, frames: 4, interleaved: false)
        let mutations: [(inout AudioStreamBasicDescription) -> Void] = [
            { $0.mFormatID = kAudioFormatMPEG4AAC },
            { $0.mFormatFlags &= ~kAudioFormatFlagIsFloat },
            { $0.mFormatFlags |= kAudioFormatFlagIsBigEndian },
            { $0.mBitsPerChannel = 64 },
            { $0.mBitsPerChannel = 16 },
            { $0.mBytesPerFrame = 8 },
            { $0.mBytesPerFrame = 0 },
            { $0.mChannelsPerFrame = 0 },
            { $0.mChannelsPerFrame = .max },
            { $0.mSampleRate = .nan }
        ]
        for mutate in mutations {
            var format = buffer.format.streamDescription.pointee
            mutate(&format)
            assertUnsupported(try Downmix.mono(fromBufferList: buffer.audioBufferList, format: format))
        }
    }

    func testMisalignedNativePointerRejectsBeforeTypedAccess() throws {
        let buffer = try makeBuffer(channels: 1, frames: 4, interleaved: false)
        try withListCopy(buffer) { list in
            list[0].mData = try XCTUnwrap(list[0].mData).advanced(by: 1)
            assertUnsupported(try Downmix.mono(fromBufferList: list.unsafePointer,
                format: buffer.format.streamDescription.pointee))
        }
    }

    func testEmptyCoherentPlanesAllowNilDataWithoutInventingSamples() throws {
        let buffer = try makeBuffer(channels: 2, frames: 0, interleaved: false)
        try withListCopy(buffer) { list in
            for index in list.indices { list[index].mData = nil }
            XCTAssertEqual(try Downmix.mono(fromBufferList: list.unsafePointer,
                format: buffer.format.streamDescription.pointee), [])
        }
    }

    private func makeBuffer(
        channels: AVAudioChannelCount, frames: AVAudioFrameCount, interleaved: Bool, rate: Double = 48_000
    ) throws -> AVAudioPCMBuffer {
        // More than two channels require an explicit layout in AVFAudio.
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: rate, interleaved: interleaved, channelLayout: layout)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames + 3))
        buffer.frameLength = frames
        return buffer
    }

    private func withListCopy(
        _ buffer: AVAudioPCMBuffer, _ body: (inout UnsafeMutableAudioBufferListPointer) throws -> Void
    ) rethrows {
        let original = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        var copy = AudioBufferList.allocate(maximumBuffers: original.count)
        defer { free(copy.unsafeMutablePointer) }
        for index in original.indices { copy[index] = original[index] }
        try withExtendedLifetime(buffer) { try body(&copy) }
    }

    private func assertUnsupported(
        _ expression: @autoclosure () throws -> [Float], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case AudioCaptureError.unsupportedFormat = error else {
                return XCTFail("expected typed unsupported format, got \(error)", file: file, line: line)
            }
        }
    }
}
