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

    func testSystemCallbackStallRequestsRecoveryWhileMicrophoneKeepsWriting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let clock = TestMonotonicClock()
        let microphone = FakeCaptureSource(channel: .microphone)
        let system = FakeRecoverableCaptureSource()
        let probe = CaptureLivenessProbe()
        let session = RecordingSession(
            outputDirectory: directory,
            livenessConfiguration: .init(stallAfter: 8, retryEvery: 8),
            monotonicNow: { clock.now })

        try await session.start(
            sources: [system, microphone],
            onChunk: { probe.record(chunk: $0) },
            onHealthEvent: { probe.record(event: $0) })

        clock.now = 1
        system.yield(at: 0)
        try await waitUntil { probe.chunkCount(for: .system) == 1 }

        clock.now = 9
        microphone.yield(at: 8)
        try await waitUntil {
            system.recoveryCount == 1
                && probe.chunkCount(for: .microphone) == 1
                && probe.events.count == 2
        }
        XCTAssertEqual(probe.events, [
            .stalled(channel: .system, secondsWithoutFrames: 8),
            .recoveryRequested(channel: .system, attempt: 1, secondsWithoutFrames: 8)
        ])

        clock.now = 10
        system.yield(at: 9)
        try await waitUntil { probe.events.count == 3 }
        XCTAssertEqual(probe.events.last, .recovered(channel: .system, outageSeconds: 9))

        let summary = await session.stop()
        XCTAssertNotNil(summary.files[.microphone])
        XCTAssertNotNil(summary.files[.system])
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: @escaping () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate() {
            if clock.now >= deadline {
                XCTFail("condition did not become true before timeout")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
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

    func testCrashRecoveryMeasuresPersistedPCMAndPublishesWithoutMemoryState() throws {
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
            try writer.append([Float](repeating: 0.25, count: 4_800))
        }

        let recovered = try CaptureFileRecovery.publish(
            stagingURL: stagingURL, finalURL: finalURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertEqual(recovered.healthStatus, .healthy)
        XCTAssertEqual(recovered.durationSeconds, 0.1, accuracy: 0.0001)
        XCTAssertEqual(recovered.peakDBFS, -12.041, accuracy: 0.02)
        XCTAssertEqual(recovered.rmsDBFS, -12.041, accuracy: 0.02)

        let revalidated = try CaptureFileRecovery.inspectPublishedFile(at: finalURL)
        XCTAssertEqual(revalidated.sha256, recovered.sha256)
        XCTAssertEqual(revalidated.byteCount, recovered.byteCount)
        XCTAssertEqual(revalidated.peakDBFS, recovered.peakDBFS, accuracy: 0.0001)
        XCTAssertEqual(revalidated.rmsDBFS, recovered.rmsDBFS, accuracy: 0.0001)

        let floatURL = directory.appendingPathComponent("float.caf")
        try autoreleasepool {
            let format = try XCTUnwrap(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false))
            let writer = try AVAudioFile(forWriting: floatURL, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: 1_600))
            buffer.frameLength = 1_600
            for index in 0..<1_600 { buffer.floatChannelData?[0][index] = 0.25 }
            try writer.write(from: buffer)
        }
        XCTAssertThrowsError(try CaptureFileRecovery.inspectPublishedFile(at: floatURL))
    }
}

final class SystemCaptureLivenessPolicyTests: XCTestCase {
    func testRequiresARealSystemFrameBeforeMonitoring() {
        var policy = SystemCaptureLivenessPolicy(configuration: .init(
            stallAfter: 8,
            retryEvery: 8))

        XCTAssertTrue(policy.observe(channel: .microphone, at: 20).isEmpty)
    }

    func testDetectsRetriesAndRecoversAStalledSystemChannel() {
        var policy = SystemCaptureLivenessPolicy(configuration: .init(
            stallAfter: 8,
            retryEvery: 8))

        XCTAssertTrue(policy.observe(channel: .system, at: 1).isEmpty)
        XCTAssertTrue(policy.observe(channel: .microphone, at: 8.9).isEmpty)
        XCTAssertEqual(policy.observe(channel: .microphone, at: 9), [
            .stalled(secondsWithoutFrames: 8),
            .recoveryDue(attempt: 1, secondsWithoutFrames: 8)
        ])
        XCTAssertTrue(policy.observe(channel: .microphone, at: 16.9).isEmpty)
        XCTAssertEqual(policy.observe(channel: .microphone, at: 17), [
            .recoveryDue(attempt: 2, secondsWithoutFrames: 16)
        ])
        XCTAssertEqual(policy.observe(channel: .system, at: 18), [
            .recovered(outageSeconds: 17)
        ])
        XCTAssertTrue(policy.observe(channel: .system, at: 19).isEmpty)
    }

    func testRoomFramesNeverHideOrTriggerTheRemoteChannelPolicy() {
        var policy = SystemCaptureLivenessPolicy(configuration: .init(
            stallAfter: 8,
            retryEvery: 8))

        XCTAssertTrue(policy.observe(channel: .system, at: 1).isEmpty)
        XCTAssertTrue(policy.observe(channel: .room, at: 20).isEmpty)
        XCTAssertEqual(policy.observe(channel: .microphone, at: 20), [
            .stalled(secondsWithoutFrames: 19),
            .recoveryDue(attempt: 1, secondsWithoutFrames: 19)
        ])
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

    func yield(at timestamp: TimeInterval) {
        lock.withLock { continuation }?.yield(AudioChunk(
            channel: channel,
            samples: [0.1],
            sampleRate: 48_000,
            timestamp: timestamp))
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

private final class FakeRecoverableCaptureSource:
    RecoverableAudioCaptureSource, @unchecked Sendable
{
    let channel = AudioChannel.system
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    private var recoveries = 0

    var recoveryCount: Int { lock.withLock { recoveries } }

    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func yield(at timestamp: TimeInterval) {
        lock.withLock { continuation }?.yield(AudioChunk(
            channel: .system,
            samples: [0.1],
            sampleRate: 48_000,
            timestamp: timestamp))
    }

    func requestRecovery() async {
        lock.withLock { recoveries += 1 }
    }

    func stop() async {
        let continuation = lock.withLock {
            let current = self.continuation
            self.continuation = nil
            return current
        }
        continuation?.finish()
    }
}

private final class TestMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    var now: TimeInterval {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class CaptureLivenessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [AudioChannel] = []
    private var capturedEvents: [RecordingCaptureHealthEvent] = []

    var events: [RecordingCaptureHealthEvent] { lock.withLock { capturedEvents } }

    func chunkCount(for channel: AudioChannel) -> Int {
        lock.withLock { channels.count(where: { $0 == channel }) }
    }

    func record(chunk: AudioChunk) {
        lock.withLock { channels.append(chunk.channel) }
    }

    func record(event: RecordingCaptureHealthEvent) {
        lock.withLock { capturedEvents.append(event) }
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
