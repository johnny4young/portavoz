import AVFAudio
import Foundation
import XCTest
@testable import AudioCaptureKit
@testable import PortavozCore

final class WAVWriterTests: XCTestCase {
    func testWritesMono16BitWAVReadableByAVAudioFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.wav")

        var framesWritten: AVAudioFramePosition = 0
        var secondsWritten: TimeInterval = 0
        try autoreleasepool {
            let writer = try WAVWriter(url: url, sampleRate: 48_000)
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

        let writer = try WAVWriter(url: url, sampleRate: 48_000)
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
