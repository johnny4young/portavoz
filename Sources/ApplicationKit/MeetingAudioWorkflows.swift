import AudioPlaybackKit
import Foundation
import Observation
import PortavozCore

/// Resolved audio assets for one meeting. The application workflow knows the
/// channel roles while the outer adapter decides where those files live.
public struct MeetingAudioChannels: Equatable, Sendable {
    public let system: URL?
    public let microphone: URL?

    public init(system: URL?, microphone: URL?) {
        self.system = system
        self.microphone = microphone
    }

    public var files: [URL] { [system, microphone].compactMap { $0 } }
    public var containsRawAudio: Bool {
        files.contains { $0.pathExtension.lowercased() != "m4a" }
    }
}

/// Outer filesystem adapter used by playback, compression, and clip export.
public protocol MeetingAudioChannelResolving: Sendable {
    func resolve(relativeAudioDirectory: String) throws -> MeetingAudioChannels
}

/// Application-owned playback facade. Presentation observes transport state
/// and sends user intents without receiving AudioPlaybackKit objects.
@MainActor
@Observable
public final class MeetingPlaybackSession {
    private let player: MeetingPlayer
    private var synchronizationTask: Task<Void, Never>?

    public private(set) var currentTime: TimeInterval
    public private(set) var duration: TimeInterval
    public private(set) var isPlaying: Bool
    public private(set) var clipRange: ClosedRange<TimeInterval>?

    public var skipSilence: Bool {
        didSet { player.skipSilence = skipSilence }
    }

    public var onlyMyVoice: Bool {
        didSet { player.onlyMyVoice = onlyMyVoice }
    }

    init(player: MeetingPlayer) {
        self.player = player
        currentTime = player.currentTime
        duration = player.duration
        isPlaying = player.isPlaying
        clipRange = player.clipRange
        skipSilence = player.skipSilence
        onlyMyVoice = player.onlyMyVoice
        synchronizationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }
                guard let self else { return }
                self.synchronize()
            }
        }
    }

    public func play() {
        player.play()
        synchronize()
    }

    public func pause() {
        player.pause()
        synchronize()
    }

    public func togglePlayPause() {
        player.togglePlayPause()
        synchronize()
    }

    public func seek(to seconds: TimeInterval) {
        player.seek(to: seconds)
        synchronize()
    }

    public func markClipStart() {
        player.markClipStart()
        synchronize()
    }

    public func markClipEnd() {
        player.markClipEnd()
        synchronize()
    }

    public func clearClip() {
        player.clearClip()
        synchronize()
    }

    public func invalidate() {
        synchronizationTask?.cancel()
        synchronizationTask = nil
        player.invalidate()
        synchronize()
    }

    private func synchronize() {
        currentTime = player.currentTime
        duration = player.duration
        isPlaying = player.isPlaying
        clipRange = player.clipRange
    }
}

/// Capability-neutral waveform sample rendered by the app.
public struct MeetingWaveformBucket: Equatable, Sendable {
    public let amplitude: Float
    public let microphoneDominant: Bool

    public init(amplitude: Float, microphoneDominant: Bool) {
        self.amplitude = amplitude
        self.microphoneDominant = microphoneDominant
    }
}

public struct PrepareMeetingPlaybackRequest: Sendable {
    public let relativeAudioDirectory: String
    public let segments: [TranscriptSegment]
    public let waveformBucketCount: Int

    public init(
        relativeAudioDirectory: String,
        segments: [TranscriptSegment],
        waveformBucketCount: Int = 600
    ) {
        self.relativeAudioDirectory = relativeAudioDirectory
        self.segments = segments
        self.waveformBucketCount = waveformBucketCount
    }
}

public struct PreparedMeetingPlayback: Sendable {
    public let session: MeetingPlaybackSession
    public let waveform: [MeetingWaveformBucket]
    public let canCompressAudio: Bool

    public init(
        session: MeetingPlaybackSession,
        waveform: [MeetingWaveformBucket],
        canCompressAudio: Bool
    ) {
        self.session = session
        self.waveform = waveform
        self.canCompressAudio = canCompressAudio
    }
}

/// Resolves channels, builds the synchronized player, derives the waveform,
/// and configures skip-silence and only-my-voice ranges as one workflow.
public struct PrepareMeetingPlayback: ApplicationUseCase {
    private let resolver: any MeetingAudioChannelResolving

    public init(resolver: any MeetingAudioChannelResolving) {
        self.resolver = resolver
    }

    public func execute(
        _ request: PrepareMeetingPlaybackRequest
    ) async throws -> PreparedMeetingPlayback? {
        try Task.checkCancellation()
        let relative = request.relativeAudioDirectory.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !relative.isEmpty else { return nil }
        let channels = try resolver.resolve(relativeAudioDirectory: relative)
        guard !channels.files.isEmpty else { return nil }
        guard let player = await MeetingPlayer.make(channelFiles: channels.files) else {
            return nil
        }

        do {
            let bucketCount = min(2_000, max(1, request.waveformBucketCount))
            let capabilityBuckets = await Task.detached(priority: .userInitiated) {
                Waveform.generate(
                    micFile: channels.microphone,
                    systemFile: channels.system,
                    buckets: bucketCount)
            }.value
            try Task.checkCancellation()
            let duration = await player.duration
            await player.setSilentRanges(
                Waveform.silentRanges(capabilityBuckets, duration: duration))
            let voiceRanges = request.segments
                .filter { $0.channel == .microphone && $0.endTime > $0.startTime }
                .map { $0.startTime...$0.endTime }
            await player.setNonVoiceRanges(
                PlaybackRanges.complement(of: voiceRanges, within: duration))
            let session = await MeetingPlaybackSession(player: player)
            return PreparedMeetingPlayback(
                session: session,
                waveform: capabilityBuckets.map {
                    MeetingWaveformBucket(
                        amplitude: $0.amplitude,
                        microphoneDominant: $0.micDominant)
                },
                canCompressAudio: channels.containsRawAudio)
        } catch {
            await player.invalidate()
            throw error
        }
    }
}

public struct CompressMeetingAudioRequest: Sendable {
    public let relativeAudioDirectory: String

    public init(relativeAudioDirectory: String) {
        self.relativeAudioDirectory = relativeAudioDirectory
    }
}

public struct MeetingAudioCompressionResult: Equatable, Sendable {
    public let bytesFreed: Int64

    public init(bytesFreed: Int64) {
        self.bytesFreed = bytesFreed
    }
}

/// Audio codec capability used by the application transaction. The concrete
/// adapter owns codec selection and filesystem publication details.
public protocol MeetingAudioCompressing: Sendable {
    func totalBytes(of files: [URL]) -> Int64
    func compress(_ sources: [URL]) async throws -> [URL]
}

/// Compresses all raw channels as one failure-safe batch and reports actual
/// disk savings.
public struct CompressMeetingAudio: ApplicationUseCase {
    private let resolver: any MeetingAudioChannelResolving
    private let compressor: any MeetingAudioCompressing

    public init(
        resolver: any MeetingAudioChannelResolving,
        compressor: any MeetingAudioCompressing
    ) {
        self.resolver = resolver
        self.compressor = compressor
    }

    public func execute(
        _ request: CompressMeetingAudioRequest
    ) async throws -> MeetingAudioCompressionResult {
        try Task.checkCancellation()
        let channels = try resolver.resolve(
            relativeAudioDirectory: request.relativeAudioDirectory)
        let raw = channels.files.filter { $0.pathExtension.lowercased() != "m4a" }
        guard !raw.isEmpty else { return MeetingAudioCompressionResult(bytesFreed: 0) }
        let before = compressor.totalBytes(of: channels.files)
        let replacements = try await compressor.compress(raw)
        // The transcode has crossed its irreversible publication boundary.
        // Cancellation must not turn a successful compression into a visible
        // failure or prevent the route from rebuilding with canonical files.
        let afterURLs = Array(Set(
            channels.files.filter { $0.pathExtension.lowercased() == "m4a" }
                + replacements
                + raw))
        let after = compressor.totalBytes(of: afterURLs)
        return MeetingAudioCompressionResult(bytesFreed: max(0, before - after))
    }
}

public struct ExportMeetingAudioClipRequest: Sendable {
    public let relativeAudioDirectory: String
    public let range: ClosedRange<TimeInterval>
    public let destination: URL

    public init(
        relativeAudioDirectory: String,
        range: ClosedRange<TimeInterval>,
        destination: URL
    ) {
        self.relativeAudioDirectory = relativeAudioDirectory
        self.range = range
        self.destination = destination
    }
}

/// Re-resolves current channels before export so a preceding compression can
/// never leave clip export pointing at stale raw files.
public struct ExportMeetingAudioClip: ApplicationUseCase {
    private let resolver: any MeetingAudioChannelResolving

    public init(resolver: any MeetingAudioChannelResolving) {
        self.resolver = resolver
    }

    public func execute(_ request: ExportMeetingAudioClipRequest) async throws {
        try Task.checkCancellation()
        let channels = try resolver.resolve(
            relativeAudioDirectory: request.relativeAudioDirectory)
        try await AudioClipExporter.export(
            channelFiles: channels.files,
            range: request.range,
            to: request.destination)
    }
}
