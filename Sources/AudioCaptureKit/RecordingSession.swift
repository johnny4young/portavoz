import Foundation
import PortavozCore

/// Coordinates capture sources and per-channel WAV writers for one meeting
/// recording. Channels stay separate on disk (`microphone.wav`,
/// `system.wav`) — the foundation of structural who-said-what.
public actor RecordingSession {
    public struct Summary: Sendable {
        public let files: [AudioChannel: URL]
        public let secondsWritten: [AudioChannel: TimeInterval]
        /// Highest absolute sample per channel (0...1). A channel that wrote
        /// audio but peaks at 0 delivered pure silence — on `.system` that
        /// almost always means the system-audio-recording permission is
        /// missing (macOS taps yield silence instead of failing).
        public let peaks: [AudioChannel: Float]
        /// Capture errors per channel; a failed channel doesn't kill the session.
        public let errors: [AudioChannel: String]

        public init(
            files: [AudioChannel: URL],
            secondsWritten: [AudioChannel: TimeInterval],
            peaks: [AudioChannel: Float] = [:],
            errors: [AudioChannel: String] = [:]
        ) {
            self.files = files
            self.secondsWritten = secondsWritten
            self.peaks = peaks
            self.errors = errors
        }

        /// Absolute difference in written duration between mic and system —
        /// the M1 acceptance metric (target < 0.05 s on a 30-min recording).
        public var driftSeconds: TimeInterval? {
            guard
                let mic = secondsWritten[.microphone],
                let system = secondsWritten[.system]
            else { return nil }
            return abs(mic - system)
        }
    }

    private let outputDirectory: URL
    private var sources: [AudioChannel: any AudioCaptureSource] = [:]
    private var writers: [AudioChannel: WAVWriter] = [:]
    private var consumers: [AudioChannel: Task<Void, Never>] = [:]
    private var peaks: [AudioChannel: Float] = [:]
    private var errors: [AudioChannel: String] = [:]
    public private(set) var isRecording = false

    public init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }

    /// Starts every source and streams its chunks into its own WAV file.
    /// Writers are created lazily on the first chunk, at the source's real
    /// sample rate.
    public func start(sources newSources: [any AudioCaptureSource]) async throws {
        guard !isRecording else { return }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        for source in newSources {
            let channel = source.channel
            let url = outputDirectory.appendingPathComponent("\(channel.rawValue).wav")
            let stream = try await source.start()
            sources[channel] = source

            consumers[channel] = Task { [weak self] in
                var writer: WAVWriter?
                var peak: Float = 0
                do {
                    for try await chunk in stream {
                        if writer == nil {
                            let created = try WAVWriter(url: url, sampleRate: chunk.sampleRate)
                            writer = created
                            await self?.register(writer: created, for: channel)
                        }
                        for sample in chunk.samples {
                            let magnitude = abs(sample)
                            if magnitude > peak { peak = magnitude }
                        }
                        try writer?.append(chunk.samples)
                    }
                    await self?.report(peak: peak, error: nil, for: channel)
                } catch {
                    // A failed channel ends its own file; the session keeps
                    // the other channels alive.
                    await self?.report(peak: peak, error: String(describing: error), for: channel)
                }
            }
        }
        isRecording = true
    }

    /// Stops all sources, drains pending chunks, and reports what was written.
    public func stop() async -> Summary {
        for source in sources.values {
            await source.stop()
        }
        for consumer in consumers.values {
            await consumer.value
        }

        var files: [AudioChannel: URL] = [:]
        var seconds: [AudioChannel: TimeInterval] = [:]
        for (channel, writer) in writers {
            files[channel] = writer.url
            seconds[channel] = writer.secondsWritten
        }
        let summary = Summary(files: files, secondsWritten: seconds, peaks: peaks, errors: errors)

        sources.removeAll()
        writers.removeAll()
        consumers.removeAll()
        peaks.removeAll()
        errors.removeAll()
        isRecording = false

        return summary
    }

    private func register(writer: WAVWriter, for channel: AudioChannel) {
        writers[channel] = writer
    }

    private func report(peak: Float, error: String?, for channel: AudioChannel) {
        peaks[channel] = peak
        if let error { errors[channel] = error }
    }
}
