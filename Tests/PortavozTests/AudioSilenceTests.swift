import AVFoundation
import XCTest

@testable import AudioCaptureKit

final class AudioSilenceTests: XCTestCase {
    // MARK: - Whole-file inspection

    /// A file whose header promises more than the bytes deliver — an imported
    /// or compressed file that lost its tail after a clean close. Concluding
    /// "silent" there would drop a channel we never finished inspecting.
    ///
    /// Deliberately *not* the capture case: `CaptureFileWriter` writes CAF with
    /// its data chunk sized to EOF, so a killed recording's declared length
    /// never exceeds its readable bytes and no mid-file read can fail.
    func testTruncatedFileIsNotReportedSilent() throws {
        let url = try writeSilentFile(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(
            AudioSilence.fileIsSilent(at: url),
            "the intact file really is silent")

        // Chop the audio data after the file was closed, so the header still
        // claims the full length. AVAudioFile then reports a length the bytes
        // cannot satisfy and the read fails part way through.
        let handle = try FileHandle(forWritingTo: url)
        let full = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? NSNumber ?? 0
        try handle.truncate(atOffset: UInt64(full.intValue / 3))
        try handle.close()

        XCTAssertFalse(
            AudioSilence.fileIsSilent(at: url),
            "a file we could not finish inspecting must keep its channel")
    }

    func testUnreadableFileKeepsItsChannel() {
        XCTAssertFalse(AudioSilence.fileIsSilent(
            at: URL(fileURLWithPath: "/nonexistent/never-recorded.caf")))
    }

    func testAudibleFileIsNotSilent() throws {
        let url = try writeSilentFile(seconds: 1, amplitude: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(AudioSilence.fileIsSilent(at: url))
    }

    private func writeSilentFile(
        seconds: Int,
        amplitude: Float = 0
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence-\(UUID().uuidString).caf")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false))
        var writer: AVAudioFile? = try AVAudioFile(
            forWriting: url,
            settings: format.settings)
        let frames = AVAudioFrameCount(48_000)
        for _ in 0..<seconds {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frames))
            buffer.frameLength = frames
            buffer.floatChannelData?[0].update(
                repeating: amplitude,
                count: Int(frames))
            try writer?.write(from: buffer)
        }
        writer = nil
        return url
    }

    func testPeakFindsLargestMagnitude() {
        XCTAssertEqual(AudioSilence.peak(of: [0.1, -0.7, 0.2]), 0.7, accuracy: 1e-6)
        XCTAssertEqual(AudioSilence.peak(of: []), 0)
    }

    func testDigitalSilenceIsSilent() {
        XCTAssertTrue(AudioSilence.isSilent([Float](repeating: 0, count: 480)))
        XCTAssertTrue(AudioSilence.isSilent([]))
    }

    func testFaintNoiseBelowFloorIsSilent() {
        // −80 dBFS ≈ 0.0001 linear, well under the −60 dBFS floor.
        XCTAssertTrue(AudioSilence.isSilent([0.0001, -0.0001, 0.00005]))
    }

    func testRealSpeechIsNotSilent() {
        XCTAssertFalse(AudioSilence.isSilent([0.5, -0.3, 0.2]))
        // −40 dBFS ≈ 0.01, comfortably above the floor.
        XCTAssertFalse(AudioSilence.isSilent([0.01, -0.012]))
    }
}
