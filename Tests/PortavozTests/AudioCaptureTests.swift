import AVFAudio
import Foundation
import XCTest
@testable import AudioCaptureKit
@testable import PortavozCore

final class CaptureFileWriterTests: XCTestCase {
    func testWritesMono16BitCAFReadableByAVAudioFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.caf")

        var framesWritten: AVAudioFramePosition = 0
        var secondsWritten: TimeInterval = 0
        try autoreleasepool {
            let writer = try CaptureFileWriter(url: url, sampleRate: 48_000)
            try writer.append([Float](repeating: 0.25, count: 4_800))
            try writer.append([Float](repeating: -0.25, count: 4_800))
            framesWritten = writer.framesWritten
            secondsWritten = writer.secondsWritten
        }

        XCTAssertEqual(framesWritten, 9_600)
        XCTAssertEqual(secondsWritten, 0.2, accuracy: 0.0001)

        let read = try AVAudioFile(forReading: url)
        XCTAssertEqual(read.length, 9_600)
        XCTAssertEqual(read.fileFormat.channelCount, 1)
        XCTAssertEqual(read.fileFormat.sampleRate, 48_000)
    }

    func testEmptyAppendIsANoOp() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try CaptureFileWriter(url: url, sampleRate: 48_000)
        try writer.append([])
        XCTAssertEqual(writer.framesWritten, 0)
    }
}

final class RecordingSummaryTests: XCTestCase {
    func testDriftRequiresBothChannels() {
        let micOnly = RecordingSession.Summary(
            files: [.microphone: URL(fileURLWithPath: "/tmp/microphone.wav")],
            secondsWritten: [.microphone: 10]
        )
        XCTAssertNil(micOnly.driftSeconds)
    }

    func testDriftIsAbsoluteDifference() {
        let summary = RecordingSession.Summary(
            files: [:],
            secondsWritten: [.microphone: 10.00, .system: 10.03]
        )
        XCTAssertEqual(summary.driftSeconds ?? 0, 0.03, accuracy: 0.0001)
    }
}

final class DownmixTests: XCTestCase {
    func testStereoBufferAveragesToMono() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<4 {
            channels[0][frame] = 1.0
            channels[1][frame] = 0.0
        }

        let mono = Downmix.mono(from: buffer)
        XCTAssertEqual(mono.count, 4)
        for value in mono {
            XCTAssertEqual(value, 0.5, accuracy: 0.0001)
        }
    }
}

final class ResampleTests: XCTestCase {
    func testSameRateIsPassthrough() {
        let samples: [Float] = [0.1, 0.2, 0.3]
        XCTAssertEqual(Resample.linear(samples, from: 48_000, to: 48_000), samples)
    }

    func testDownsamplePreservesDurationAndShape() {
        // 1 s of a ramp at 48 kHz → 24 kHz keeps 1 s and stays monotonic.
        let source = (0..<48_000).map { Float($0) / 48_000 }
        let out = Resample.linear(source, from: 48_000, to: 24_000)
        XCTAssertEqual(out.count, 24_000)
        XCTAssertEqual(out.first ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(out.last ?? -1, 1, accuracy: 0.001)
        for index in 1..<out.count {
            XCTAssertGreaterThanOrEqual(out[index], out[index - 1])
        }
    }

    func testUpsampleInterpolatesBetweenNeighbors() {
        // 24 kHz → 48 kHz doubles the samples; odd indices are midpoints.
        let out = Resample.linear([0, 1, 0, 1], from: 24_000, to: 48_000)
        XCTAssertEqual(out.count, 8)
        XCTAssertEqual(out[0], 0, accuracy: 0.0001)
        XCTAssertEqual(out[1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(out[2], 1, accuracy: 0.0001)
        XCTAssertEqual(out[3], 0.5, accuracy: 0.0001)
    }

    func testConstantSignalStaysConstantAtWeirdRatio() {
        let out = Resample.linear(
            [Float](repeating: 0.7, count: 441), from: 44_100, to: 48_000)
        XCTAssertEqual(out.count, 480)
        for value in out {
            XCTAssertEqual(value, 0.7, accuracy: 0.0001)
        }
    }
}
