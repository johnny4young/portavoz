import AVFoundation
import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@MainActor
final class MeetingAudioWorkflowTests: XCTestCase {
    func testPreparationBuildsApplicationPlaybackAndCapabilityNeutralWaveform() async throws {
        let fixture = try MeetingAudioWorkflowFixture()
        defer { fixture.remove() }
        let request = PrepareMeetingPlaybackRequest(
            relativeAudioDirectory: "Audio/meeting",
            segments: [TranscriptSegment(
                meetingID: MeetingID(),
                channel: .microphone,
                text: "Hello",
                startTime: 0,
                endTime: 0.8,
                isFinal: true)],
            waveformBucketCount: 32)

        let prepared = try await PrepareMeetingPlayback(
            resolver: fixture.resolver, compressionAdmission: AllowAudioCompression()).execute(request)

        let playback = try XCTUnwrap(prepared)
        XCTAssertEqual(playback.waveform.count, 32)
        XCTAssertTrue(playback.waveform.contains { $0.amplitude > 0 })
        XCTAssertTrue(playback.canCompressAudio)
        XCTAssertGreaterThan(playback.session.duration, 0.5)
        XCTAssertTrue(playback.session.canClearPlayback)
        playback.session.seek(to: 0.5)
        XCTAssertEqual(playback.session.currentTime, 0.5, accuracy: 0.001)
        playback.session.markClipStart()
        playback.session.seek(to: 0.8)
        playback.session.markClipEnd()
        XCTAssertEqual(playback.session.clipRange, 0.5...0.8)
        let speaker = SpeakerID()
        playback.session.focus(on: speaker)
        XCTAssertEqual(playback.session.voiceFocus, speaker)
        playback.session.focus(on: nil)
        XCTAssertNil(playback.session.voiceFocus)
        XCTAssertTrue(playback.session.skipSilence, "dead time is skipped by default")
        playback.session.rate = 1.5
        XCTAssertEqual(playback.session.rate, 1.5)
        playback.session.invalidate()
    }

    func testMicOnlyPlaybackNeverOffersChannelAttenuation() async throws {
        let fixture = try MeetingAudioWorkflowFixture()
        defer { fixture.remove() }
        let resolver = MeetingAudioResolverFake(channels: MeetingAudioChannels(
            system: nil,
            microphone: fixture.resolver.channels.microphone))

        let prepared = try await PrepareMeetingPlayback(resolver: resolver, compressionAdmission: AllowAudioCompression()).execute(
            PrepareMeetingPlaybackRequest(
                relativeAudioDirectory: "Audio/meeting",
                segments: []))

        let playback = try XCTUnwrap(prepared)
        XCTAssertFalse(
            playback.session.canClearPlayback,
            "mic-only and in-person recordings must preserve their complete source")
        playback.session.invalidate()
    }

    func testPreparationPublishesOneBoundedWaveformSnapshot() async throws {
        let fixture = try MeetingAudioWorkflowFixture()
        defer { fixture.remove() }

        let prepared = try await PrepareMeetingPlayback(
            resolver: fixture.resolver, compressionAdmission: AllowAudioCompression()).execute(
                PrepareMeetingPlaybackRequest(
                    relativeAudioDirectory: "Audio/meeting",
                    segments: [],
                    waveformBucketCount: .max))

        let playback = try XCTUnwrap(prepared)
        XCTAssertEqual(
            playback.waveform.count,
            MeetingWaveformDeliveryPolicy.maximumBucketCount)
        playback.session.invalidate()
    }

    func testCompressionReportsSavingsAndPublishesBothCurrentChannels() async throws {
        // A one-second PCM fixture can be smaller than its AAC container on
        // some macOS encoders. Use enough material to assert real savings.
        let fixture = try MeetingAudioWorkflowFixture(seconds: 10)
        defer { fixture.remove() }
        let before = fixture.resolver.channels.files

        let recorder = ResourceWorkloadEventRecorder()
        let result = try await CompressMeetingAudio(
            resolver: fixture.resolver,
            compressor: MeetingAudioCompressorFake(),
            compressionAdmission: AllowAudioCompression(),
            telemetry: ResourceWorkloadTelemetry(receiver: recorder.receive)
        ).execute(CompressMeetingAudioRequest(relativeAudioDirectory: "Audio/meeting"))

        XCTAssertGreaterThan(result.bytesFreed, 0)
        XCTAssertTrue(before.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        for name in ["system.m4a", "microphone.m4a"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: fixture.directory.appendingPathComponent(name).path))
        }
        assertMatchedWorkload(
            recorder.events,
            descriptor: ResourceWorkloadDescriptor(
                workloadClass: .userInitiated,
                kind: .mediaExport,
                operation: .execute))
    }

    func testOnlyLosslessChannelsAreCompressible() async {
        for fileExtension in ["caf", "wav", "aiff", "aif", "WAV"] {
            let channels = MeetingAudioChannels(
                system: URL(fileURLWithPath: "/meeting/system.\(fileExtension)"), microphone: nil)
            XCTAssertTrue(channels.containsRawAudio, fileExtension)
        }
        for fileExtension in ["m4a", "mp3", "aac", "m4b"] {
            let channels = MeetingAudioChannels(
                system: URL(fileURLWithPath: "/meeting/system.\(fileExtension)"), microphone: nil)
            XCTAssertFalse(channels.containsRawAudio, fileExtension)
        }
    }

    func testCompressionKeepsImportedLossyChannelBytesAndCountsThemOnBothSides() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("application-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = directory.appendingPathComponent("system.mp3")
        let microphone = directory.appendingPathComponent("microphone.wav")
        let imported = Data(repeating: 0x11, count: 4_096)
        try imported.write(to: system)
        try Data(repeating: 0x22, count: 8_192).write(to: microphone)

        let result = try await CompressMeetingAudio(
            resolver: MeetingAudioResolverFake(channels: MeetingAudioChannels(system: system, microphone: microphone)),
            compressor: MeetingAudioCompressorFake(),
            compressionAdmission: AllowAudioCompression()
        ).execute(CompressMeetingAudioRequest(relativeAudioDirectory: "Audio/meeting"))

        XCTAssertEqual(try Data(contentsOf: system), imported)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("microphone.m4a").path))
        XCTAssertEqual(result.bytesFreed, 8_192 - 1_024)
    }

    func testMissingAudioDegradesToTextOnlyWithoutBuildingAPlayer() async throws {
        let resolver = MeetingAudioResolverFake(channels: MeetingAudioChannels(
            system: nil,
            microphone: nil))

        let prepared = try await PrepareMeetingPlayback(resolver: resolver, compressionAdmission: AllowAudioCompression()).execute(
            PrepareMeetingPlaybackRequest(
                relativeAudioDirectory: "Audio/missing",
                segments: []))

        XCTAssertNil(prepared)
    }

    private func assertMatchedWorkload(
        _ events: [ResourceWorkloadEvent],
        descriptor: ResourceWorkloadDescriptor
    ) {
        guard case .started(let started) = events.first,
              case .finished(let finished, let outcome) = events.last
        else {
            return XCTFail("Expected one matched resource workload")
        }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(started, finished)
        XCTAssertEqual(started.descriptor, descriptor)
        XCTAssertEqual(outcome, .completed)
    }
}

private struct MeetingAudioWorkflowFixture {
    let directory: URL
    let resolver: MeetingAudioResolverFake

    init(seconds: Double = 1) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("application-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let system = directory.appendingPathComponent("system.wav")
        let microphone = directory.appendingPathComponent("microphone.wav")
        try Self.writeWAV(to: system, frequency: 220, seconds: seconds)
        try Self.writeWAV(to: microphone, frequency: 330, seconds: seconds)
        resolver = MeetingAudioResolverFake(channels: MeetingAudioChannels(
            system: system,
            microphone: microphone))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func writeWAV(
        to url: URL,
        frequency: Double,
        seconds: Double
    ) throws {
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
            channel[index] = 0.25 * Float(
                sin(2 * Double.pi * frequency * Double(index) / rate))
        }
        try writer!.write(from: buffer)
        writer = nil
    }
}

private struct MeetingAudioResolverFake: MeetingAudioChannelResolving {
    let channels: MeetingAudioChannels

    func resolve(relativeAudioDirectory: String) throws -> MeetingAudioChannels {
        channels
    }
}

private struct MeetingAudioCompressorFake: MeetingAudioCompressing {
    func totalBytes(of files: [URL]) -> Int64 {
        files.reduce(0) { total, file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    func compress(_ sources: [URL]) async throws -> [URL] {
        try sources.map { source in
            let output = source.deletingPathExtension().appendingPathExtension("m4a")
            try Data(repeating: 0x2A, count: 1_024).write(to: output)
            try FileManager.default.removeItem(at: source)
            return output
        }
    }
}

private struct AllowAudioCompression: MeetingAudioCompressionChecking {
    func canCompressMeetingAudio(relativeAudioDirectory: String) -> Bool { true }
}
