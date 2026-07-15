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
        let url = directory.appendingPathComponent("test.partial.caf")

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

    func testStartStopsAlreadyStartedSourcesWhenLaterSourceFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = FakeCaptureSource(channel: .microphone)
        let failing = FakeCaptureSource(channel: .system, startError: FakeCaptureError.startFailed)
        let session = RecordingSession(outputDirectory: directory)

        do {
            try await session.start(sources: [started, failing])
            XCTFail("Expected the second source to fail startup")
        } catch FakeCaptureError.startFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(started.stopCount, 1)
        XCTAssertEqual(failing.stopCount, 0)
        let isRecording = await session.isRecording
        XCTAssertFalse(isRecording)

        let summary = await session.stop()
        XCTAssertTrue(summary.files.isEmpty)
    }

    func testStopPublishesValidatedCAFAndCompleteMediaEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = [Float](repeating: 0.25, count: 4_800)
        let source = FakeCaptureSource(
            channel: .microphone,
            chunks: [AudioChunk(
                channel: .microphone,
                samples: samples,
                sampleRate: 48_000,
                timestamp: 0)])
        let session = RecordingSession(outputDirectory: directory)

        try await session.start(sources: [source])
        let finalURL = directory.appendingPathComponent(
            AudioCapturePath.publishedFilename(for: .microphone))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))

        let summary = await session.stop()
        let media = try XCTUnwrap(summary.publishedFiles[.microphone])
        let stagingURL = directory.appendingPathComponent(
            AudioCapturePath.stagingFilename(for: .microphone))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertEqual(summary.files[.microphone], finalURL)
        XCTAssertEqual(media.url, finalURL)
        XCTAssertEqual(media.container, "caf")
        XCTAssertEqual(media.codec, "pcm-s16le")
        XCTAssertEqual(media.sampleRate, 48_000)
        XCTAssertEqual(media.channelCount, 1)
        XCTAssertEqual(media.durationSeconds, 0.1, accuracy: 0.0001)
        XCTAssertGreaterThan(media.byteCount, 0)
        XCTAssertEqual(media.sha256.count, 64)
        XCTAssertTrue(media.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(media.healthStatus, .healthy)
        XCTAssertEqual(media.peakDBFS, -12.041, accuracy: 0.01)
        XCTAssertEqual(media.rmsDBFS, -12.041, accuracy: 0.01)
    }

    func testPublisherNeverOverwritesAnExistingFinalFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stagingURL = directory.appendingPathComponent(
            AudioCapturePath.stagingFilename(for: .microphone))
        let finalURL = directory.appendingPathComponent(
            AudioCapturePath.publishedFilename(for: .microphone))
        try autoreleasepool {
            let writer = try CaptureFileWriter(url: stagingURL, sampleRate: 48_000)
            try writer.append([Float](repeating: 0, count: 480))
        }
        let existing = Data("do-not-overwrite".utf8)
        try existing.write(to: finalURL)

        XCTAssertThrowsError(try CaptureFilePublisher.publish(
            stagingURL: stagingURL,
            finalURL: finalURL,
            peak: 0,
            rms: 0)) { error in
            guard case AudioCaptureError.captureDestinationExists(let path) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(path, finalURL.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertEqual(try Data(contentsOf: finalURL), existing)
    }

    func testPublicationClassifiesSilenceAndClampedPCMClipping() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func record(_ samples: [Float], in name: String) async throws -> PublishedCaptureFile {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let source = FakeCaptureSource(
                channel: .microphone,
                chunks: [AudioChunk(
                    channel: .microphone,
                    samples: samples,
                    sampleRate: 48_000,
                    timestamp: 0)])
            let session = RecordingSession(outputDirectory: directory)
            try await session.start(sources: [source])
            let summary = await session.stop()
            return try XCTUnwrap(summary.publishedFiles[.microphone])
        }

        let silent = try await record([Float](repeating: 0, count: 480), in: "silent")
        XCTAssertEqual(silent.healthStatus, .silent)
        XCTAssertEqual(silent.peakDBFS, -160, accuracy: 0.001)
        XCTAssertEqual(silent.rmsDBFS, -160, accuracy: 0.001)

        let clipped = try await record([Float](repeating: 2, count: 480), in: "clipped")
        XCTAssertEqual(clipped.healthStatus, .clipped)
        XCTAssertEqual(clipped.peakDBFS, 0, accuracy: 0.001)
        XCTAssertEqual(clipped.rmsDBFS, 0, accuracy: 0.001)
    }
}

private enum FakeCaptureError: Error {
    case startFailed
}

private final class FakeCaptureSource: AudioCaptureSource, @unchecked Sendable {
    let channel: AudioChannel
    private let startError: Error?
    private let chunks: [AudioChunk]
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    private var stops = 0

    init(
        channel: AudioChannel,
        startError: Error? = nil,
        chunks: [AudioChunk] = []
    ) {
        self.channel = channel
        self.startError = startError
        self.chunks = chunks
    }

    var stopCount: Int {
        lock.withLock { stops }
    }

    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        if let startError { throw startError }
        let (stream, continuation) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
        lock.withLock {
            self.continuation = continuation
        }
        for chunk in chunks { continuation.yield(chunk) }
        return stream
    }

    func stop() async {
        let continuation = lock.withLock {
            stops += 1
            let current = self.continuation
            self.continuation = nil
            return current
        }
        continuation?.finish()
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
