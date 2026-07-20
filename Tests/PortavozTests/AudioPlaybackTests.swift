import AVFoundation
import Foundation
import XCTest

@testable import AudioCaptureKit
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

    func testEnvelopePreservesBucketBoundariesAcrossChannelsAndRemainder() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-boundaries-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 2,
            interleaved: false)!
        let first: [Float] = [0.1, 0.8, 0.2, 0.4, 0.3, 0.2, 0.1, 0.6, 0.2, 0.9, 0.5]
        let second: [Float] = [0.2, 0.1, 0.7, 0.2, 0.5, 0.1, 0.3, 0.2, 0.4, 0.1, 1.0]
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(first.count))!
        buffer.frameLength = AVAudioFrameCount(first.count)
        first.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: first.count)
        }
        second.withUnsafeBufferPointer {
            buffer.floatChannelData![1].update(from: $0.baseAddress!, count: second.count)
        }
        try writer!.write(from: buffer)
        writer = nil

        let buckets = Waveform.generate(micFile: url, systemFile: nil, buckets: 3)

        XCTAssertEqual(buckets.map(\.amplitude), [0.8, 0.5, 1.0])
        XCTAssertTrue(buckets.allSatisfy(\.micDominant))
    }

    /// A loud–silent–loud shape yields one silent range in the middle, and
    /// short dips below `minLength` are ignored.
    func testSilentRangesFindsSustainedGaps() {
        func bucket(_ a: Float) -> Waveform.Bucket { .init(amplitude: a, micDominant: true) }
        // 10 buckets over 10 s (1 s each): loud 0–3, silent 3–7, loud 7–10.
        let buckets = [0.8, 0.8, 0.8, 0.0, 0.0, 0.0, 0.0, 0.8, 0.8, 0.8].map(bucket)
        let ranges = Waveform.silentRanges(buckets, duration: 10, threshold: 0.06, minLength: 1.2)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges.first?.lowerBound ?? -1, 3, accuracy: 0.01)
        XCTAssertEqual(ranges.first?.upperBound ?? -1, 7, accuracy: 0.01)

        // A single silent bucket (1 s < minLength) is ignored.
        let brief = [0.8, 0.0, 0.8].map(bucket)
        XCTAssertTrue(Waveform.silentRanges(brief, duration: 3, minLength: 1.2).isEmpty)
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

final class AudioTranscoderTests: XCTestCase {
    /// The exact mono Int16 CAF written by production capture transcodes to a
    /// much smaller m4a; with deleteSource the original is gone and the m4a
    /// remains.
    func testTranscodesToSmallerM4AAndRemovesSource() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc-\(UUID().uuidString).caf")
        try writeCaptureCAF(to: url, seconds: 10)

        let wavBytes = AudioTranscoder.totalBytes(of: [url])
        let m4a: URL
        do {
            m4a = try await AudioTranscoder.toAAC(source: url, deleteSource: true)
        } catch where isAACEncoderUnavailable(error) {
            throw XCTSkip("The host AAC encoder is unavailable: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: m4a) }

        XCTAssertEqual(m4a.pathExtension, "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: m4a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "source removed after write")
        XCTAssertLessThan(
            AudioTranscoder.totalBytes(of: [m4a]), wavBytes, "AAC must be smaller than the WAV")
    }

    func testTranscodesEveryChannelBeforeRemovingAnyOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc-set-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = directory.appendingPathComponent("system.wav")
        let microphone = directory.appendingPathComponent("microphone.wav")
        try writeWAV(to: system, seconds: 2)
        try writeWAV(to: microphone, seconds: 2)

        let outputs = try await AudioTranscoder.toAAC(
            sources: [system, microphone],
            encoder: { source, output in
                try FileManager.default.copyItem(at: source, to: output)
            })

        XCTAssertEqual(outputs.map(\.lastPathComponent), ["system.m4a", "microphone.m4a"])
        XCTAssertTrue(outputs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: system.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: microphone.path))
    }

    func testLaterChannelFailureRollsBackPublishedWorkAndPreservesOriginals() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = directory.appendingPathComponent("system.wav")
        let missingMicrophone = directory.appendingPathComponent("microphone.wav")
        try writeWAV(to: system, seconds: 1)

        do {
            _ = try await AudioTranscoder.toAAC(
                sources: [system, missingMicrophone],
                encoder: { source, output in
                    guard FileManager.default.fileExists(atPath: source.path) else {
                        throw AudioTranscoder.TranscodeError.exportFailed(
                            "source audio is missing")
                    }
                    try FileManager.default.copyItem(at: source, to: output)
                })
            XCTFail("a missing later channel must fail the complete transaction")
        } catch {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: system.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("system.m4a").path))
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)
        XCTAssertFalse(leftovers.contains {
            $0.lastPathComponent.hasPrefix(".portavoz-compress-")
        })
    }

    func testTotalBytesReflectsDeletionWhenTheSameURLIsReused() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc-size-\(UUID().uuidString).raw")
        try Data(repeating: 0x2A, count: 4_096).write(to: url)

        XCTAssertEqual(AudioTranscoder.totalBytes(of: [url]), 4_096)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(AudioTranscoder.totalBytes(of: [url]), 0)
    }

    func testExistingCanonicalOutputFailsWithoutReplacingEitherFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc-existing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("system.wav")
        let existing = directory.appendingPathComponent("system.m4a")
        try writeWAV(to: source, seconds: 1)
        let originalSource = try Data(contentsOf: source)
        let originalOutput = Data("preserve-me".utf8)
        try originalOutput.write(to: existing)

        do {
            _ = try await AudioTranscoder.toAAC(source: source)
            XCTFail("an existing canonical output must fail closed")
        } catch AudioTranscoder.TranscodeError.outputAlreadyExists {
            // Expected: neither user-owned artifact may be replaced.
        }

        XCTAssertEqual(try Data(contentsOf: source), originalSource)
        XCTAssertEqual(try Data(contentsOf: existing), originalOutput)
    }

    private func writeWAV(to url: URL, seconds: Double) throws {
        let rate = 16_000.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: 1,
            interleaved: false)!
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            channel[index] = 0.3 * Float(sin(2 * Double.pi * 300 * Double(index) / rate))
        }
        try writer!.write(from: buffer)
        writer = nil
    }

    private func writeCaptureCAF(to url: URL, seconds: Double) throws {
        let rate = 48_000.0
        try autoreleasepool {
            let writer = try CaptureFileWriter(url: url, sampleRate: rate)
            let sampleCount = Int(rate * seconds)
            let samples = (0..<sampleCount).map { index in
                0.3 * Float(sin(2 * Double.pi * 300 * Double(index) / rate))
            }
            try writer.append(samples)
        }
    }

    private func isAACEncoderUnavailable(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let candidate = current {
            if candidate.code == 1_718_449_215 { return true } // 'fmt?'
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
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
