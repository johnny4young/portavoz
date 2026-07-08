import AVFoundation
import Foundation
import XCTest

@testable import AudioPlaybackKit

final class WaveformTests: XCTestCase {
    /// Writes a WAV whose first half is loud and second half silent, then
    /// checks the envelope reflects that shape and normalizes to 0…1.
    func testEnvelopeReflectsLoudThenSilent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let rate = 16_000.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(rate)  // 1 second
        // Optional so we can nil it out — AVAudioFile flushes to disk on
        // dealloc, and generate() reads the file back in the same test.
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            channel[i] = i < Int(frames) / 2 ? 0.8 : 0.0
        }
        try writer!.write(from: buffer)
        writer = nil

        let buckets = Waveform.generate(micFile: url, systemFile: nil, buckets: 10)
        XCTAssertEqual(buckets.count, 10)
        XCTAssertEqual(buckets.first?.amplitude ?? 0, 1.0, accuracy: 0.01, "loud start normalizes to 1")
        XCTAssertEqual(buckets.last?.amplitude ?? 1, 0.0, accuracy: 0.01, "silent tail reads ~0")
        XCTAssertTrue(buckets.allSatisfy(\.micDominant), "only the mic channel had signal")
    }

    func testEmptyWhenNothingReadable() {
        XCTAssertTrue(Waveform.generate(micFile: nil, systemFile: nil, buckets: 100).isEmpty)
        XCTAssertTrue(
            Waveform.generate(
                micFile: URL(fileURLWithPath: "/nope.wav"), systemFile: nil, buckets: 100
            ).isEmpty)
    }
}

final class AudioClipExporterTests: XCTestCase {
    private func writeWAV(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-src-\(UUID().uuidString).wav")
        let rate = 16_000.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            channel[i] = 0.4 * Float(sin(2 * Double.pi * 330 * Double(i) / rate))
        }
        try writer!.write(from: buffer)
        writer = nil
        return url
    }

    /// A clip of a range writes a valid m4a of ~the right duration, fast.
    func testExportsRangeToM4A() async throws {
        let source = try writeWAV(seconds: 30)
        defer { try? FileManager.default.removeItem(at: source) }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-out-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: output) }

        try await AudioClipExporter.export(channelFiles: [source], range: 5...20, to: output)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let clip = AVURLAsset(url: output)
        let duration = try await clip.load(.duration).seconds
        XCTAssertEqual(duration, 15, accuracy: 0.5, "the clip must be ~15 s long")
    }

    func testRejectsInvalidRangeAndMissingAudio() async {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("x.m4a")
        do {
            try await AudioClipExporter.export(
                channelFiles: [URL(fileURLWithPath: "/nope.wav")], range: 0...1, to: out)
            XCTFail("missing audio must throw")
        } catch {}
    }
}

final class MeetingPlayerTests: XCTestCase {
    @MainActor
    func testMakeReturnsNilWhenNoChannelFileExists() async {
        let player = await MeetingPlayer.make(
            channelFiles: [URL(fileURLWithPath: "/nonexistent/system.caf")])
        XCTAssertNil(player, "a player over missing audio must not be built")
    }

    @MainActor
    func testMakeReturnsNilForEmptyList() async {
        let player = await MeetingPlayer.make(channelFiles: [])
        XCTAssertNil(player)
    }
}
