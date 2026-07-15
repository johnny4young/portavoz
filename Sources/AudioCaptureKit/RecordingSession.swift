import Foundation
import PortavozCore

/// Coordinates capture sources and per-channel writers for one meeting
/// recording. Channels stay separate on disk (`microphone.caf`,
/// `system.caf` — CAF for crash-safety) — the foundation of structural
/// who-said-what.
public actor RecordingSession {
    public struct Summary: Sendable {
        /// Reader-visible files that passed inspection and atomic publication.
        public let files: [AudioChannel: URL]
        /// Finalized media evidence keyed by structural capture channel.
        public let publishedFiles: [AudioChannel: PublishedCaptureFile]
        public let secondsWritten: [AudioChannel: TimeInterval]
        /// Highest absolute sample per channel (0...1). A channel that wrote
        /// audio but peaks at 0 delivered pure silence — on `.system` that
        /// almost always means the system-audio-recording permission is
        /// missing (macOS taps yield silence instead of failing).
        public let peaks: [AudioChannel: Float]
        /// Root-mean-square amplitude per channel (0...1 for normal PCM).
        public let rms: [AudioChannel: Float]
        /// Capture errors per channel; a failed channel doesn't kill the session.
        public let errors: [AudioChannel: String]

        public init(
            files: [AudioChannel: URL],
            secondsWritten: [AudioChannel: TimeInterval],
            peaks: [AudioChannel: Float] = [:],
            rms: [AudioChannel: Float] = [:],
            publishedFiles: [AudioChannel: PublishedCaptureFile] = [:],
            errors: [AudioChannel: String] = [:]
        ) {
            self.files = files
            self.publishedFiles = publishedFiles
            self.secondsWritten = secondsWritten
            self.peaks = peaks
            self.rms = rms
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
    private var writers: [AudioChannel: CaptureFileWriter] = [:]
    private var consumers: [AudioChannel: Task<Void, Never>] = [:]
    private var peaks: [AudioChannel: Float] = [:]
    private var rms: [AudioChannel: Float] = [:]
    private var errors: [AudioChannel: String] = [:]
    public private(set) var isRecording = false

    public init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }

    /// Starts every source and streams its chunks into its own CAF file.
    /// Writers are created lazily on the first chunk, at the source's real
    /// sample rate.
    ///
    /// `onChunk` observes every chunk *after* it is persisted — the seam
    /// where live transcription hangs off the recording pipeline without
    /// the writer ever waiting on it.
    public func start(
        sources newSources: [any AudioCaptureSource],
        onChunk: (@Sendable (AudioChunk) -> Void)? = nil
    ) async throws {
        guard !isRecording else { return }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        do {
            for source in newSources {
                let channel = source.channel
                let stagingURL = outputDirectory.appendingPathComponent(
                    AudioCapturePath.stagingFilename(for: channel))
                let stream = try await source.start()
                sources[channel] = source

                consumers[channel] = Task { [weak self] in
                    var writer: CaptureFileWriter?
                    var peak: Float = 0
                    var sumSquares = 0.0
                    var sampleCount: Int64 = 0
                    do {
                        for try await chunk in stream {
                            if writer == nil {
                                let created = try CaptureFileWriter(
                                    url: stagingURL, sampleRate: chunk.sampleRate)
                                writer = created
                                await self?.register(writer: created, for: channel)
                            }
                            try writer?.append(chunk.samples)
                            // Signal evidence must describe bytes that were
                            // actually accepted by the writer. Clamp to the
                            // signed-PCM range because the file conversion
                            // clips out-of-range Float32 input to that range.
                            for sample in chunk.samples {
                                let magnitude = min(abs(sample), 1)
                                if magnitude > peak { peak = magnitude }
                                sumSquares += Double(magnitude) * Double(magnitude)
                            }
                            sampleCount += Int64(chunk.samples.count)
                            onChunk?(chunk)
                        }
                        let measuredRMS = sampleCount > 0
                            ? Float((sumSquares / Double(sampleCount)).squareRoot()) : 0
                        await self?.report(
                            peak: peak, rms: measuredRMS, error: nil, for: channel)
                    } catch {
                        // A failed channel ends its own file; the session keeps
                        // the other channels alive.
                        let measuredRMS = sampleCount > 0
                            ? Float((sumSquares / Double(sampleCount)).squareRoot()) : 0
                        await self?.report(
                            peak: peak,
                            rms: measuredRMS,
                            error: String(describing: error),
                            for: channel)
                    }
                }
            }
        } catch {
            // Startup is all-or-nothing: if mic starts but the system tap fails
            // (or any later source fails), release the sources that are already
            // live so we never leave privacy-sensitive capture running.
            _ = await stop()
            throw error
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

        var seconds: [AudioChannel: TimeInterval] = [:]
        for (channel, writer) in writers {
            seconds[channel] = writer.secondsWritten
        }

        // Capture only value snapshots before releasing every AVAudioFile.
        // Publication happens after those handles close.
        let stagingURLs = writers.mapValues(\.url)
        let measuredPeaks = peaks
        let measuredRMS = rms

        sources.removeAll()
        writers.removeAll()
        consumers.removeAll()
        isRecording = false

        var files: [AudioChannel: URL] = [:]
        var published: [AudioChannel: PublishedCaptureFile] = [:]
        for (channel, stagingURL) in stagingURLs {
            let finalURL = outputDirectory.appendingPathComponent(
                AudioCapturePath.publishedFilename(for: channel))
            do {
                let result = try CaptureFilePublisher.publish(
                    stagingURL: stagingURL,
                    finalURL: finalURL,
                    peak: measuredPeaks[channel] ?? 0,
                    rms: measuredRMS[channel] ?? 0)
                files[channel] = result.url
                published[channel] = result
            } catch {
                errors[channel] = errors[channel].map { "\($0); \(error)" }
                    ?? String(describing: error)
            }
        }
        let summary = Summary(
            files: files,
            secondsWritten: seconds,
            peaks: measuredPeaks,
            rms: measuredRMS,
            publishedFiles: published,
            errors: errors)

        peaks.removeAll()
        rms.removeAll()
        errors.removeAll()

        return summary
    }

    private func register(writer: CaptureFileWriter, for channel: AudioChannel) {
        writers[channel] = writer
    }

    private func report(
        peak: Float,
        rms: Float,
        error: String?,
        for channel: AudioChannel
    ) {
        peaks[channel] = peak
        self.rms[channel] = rms
        if let error { errors[channel] = error }
    }
}
