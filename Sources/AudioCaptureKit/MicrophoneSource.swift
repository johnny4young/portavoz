import AudioToolbox
import AVFAudio
import Foundation
import PortavozCore

/// Captures the local microphone through AVAudioEngine at the device's
/// native format, downmixed to mono. Recording keeps native quality;
/// resampling for STT is TranscriptionKit's job.
///
/// Two real-world hazards are handled here:
/// - **Device changes mid-recording** (plugging in headphones): the engine
///   stops silently. We listen for `AVAudioEngineConfigurationChange`,
///   reinstall the tap and restart; if the replacement device runs at a
///   different rate its audio is resampled to the stream's original rate,
///   and the capture gap is padded with silence so the file stays aligned
///   with the system channel.
/// - **Acoustic echo**: with speakers, the mic hears the meeting audio and
///   every remote participant becomes a phantom "Me". Voice processing
///   (Apple's AEC) subtracts the system output from the mic signal.
///
/// `@unchecked Sendable`: the engine and continuation are mutated only from
/// `start()`/`stop()` and the serial `restartQueue`; the tap block runs
/// serialized on the render thread and closes over its own continuation.
public final class MicrophoneSource: AudioCaptureSource, @unchecked Sendable {
    public let channel: AudioChannel = .microphone

    private let engine = AVAudioEngine()
    private let clock = HostClock()
    private let deviceIdentifier: String?
    private let voiceProcessing: Bool
    private let restartQueue = DispatchQueue(label: "app.portavoz.mic-restart")
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    private var observer: (any NSObjectProtocol)?
    /// Rate of the first device; the stream promises this rate for its whole
    /// life, so replacement devices get resampled to it. Written once.
    private var streamSampleRate: Double = 0
    /// Total samples yielded so far, for gap accounting after a device
    /// change. Touched from the render thread and the restart queue.
    private let deliveredLock = NSLock()
    private var samplesDelivered = 0

    /// - Parameters:
    ///   - deviceIdentifier: UID or name of the input device to use (macOS).
    ///     Nil uses the system default input.
    ///   - voiceProcessing: enables Apple's echo cancellation so the mic
    ///     channel carries only the local voice even on speakers. On by
    ///     default; disable for raw capture.
    public init(deviceIdentifier: String? = nil, voiceProcessing: Bool = true) {
        self.deviceIdentifier = deviceIdentifier
        self.voiceProcessing = voiceProcessing
    }

    /// Starts the engine (and the echo canceller) WITHOUT a tap, so the
    /// AEC's adaptive filter converges while the app is still preparing
    /// models. Without it, the first seconds of a recording leak echo
    /// (measured: mic/system RMS ratio 0.38 in the first 2 s, 0.03–0.11
    /// once converged). Yields no chunks and the session clock still
    /// anchors at the first real tap callback. Safe to skip — `start()`
    /// does the full setup itself when the engine isn't warm.
    public func warmUp() async {
        restartQueue.sync {
            guard continuation == nil, !engine.isRunning else { return }
            try? applyPinnedDeviceIfNeeded(required: false)
            applyVoiceProcessingIfEnabled()
            engine.prepare()
            try? engine.start()
        }
    }

    public func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        let input = engine.inputNode
        if !engine.isRunning {
            // Cold start; a warm engine already has device + AEC applied.
            try applyPinnedDeviceIfNeeded(required: true)
            applyVoiceProcessingIfEnabled()
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        let (stream, continuation) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
        self.continuation = continuation
        streamSampleRate = format.sampleRate
        installTap()

        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleRestart()
        }

        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                teardown()
                throw error
            }
        }
        return stream
    }

    private func applyVoiceProcessingIfEnabled() {
        guard voiceProcessing else { return }
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            // Without this, enabling AEC ducks the very meeting audio the
            // user is listening to.
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false, duckingLevel: .min)
        } catch {
            // Some devices reject voice processing; raw capture with echo
            // beats no capture.
        }
    }

    public func stop() async {
        restartQueue.sync {
            teardown()
        }
    }

    /// Must run on `restartQueue` (or before the stream exists, in `start`).
    private func teardown() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }

    /// Installs the tap at the CURRENT device format, resampling to the
    /// stream's original rate when they differ, and padding any capture gap
    /// (device switch downtime) with silence to keep the timeline aligned.
    private func installTap() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let native = format.sampleRate
        let target = streamSampleRate
        guard native > 0, target > 0, let continuation else { return }

        let clock = clock
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self else { return }
            var samples = Downmix.mono(from: buffer)
            guard !samples.isEmpty else { return }
            if native != target {
                samples = Resample.linear(samples, from: native, to: target)
            }
            let elapsed = clock.elapsed(hostTime: when.hostTime)
            let expected = Int(elapsed * target)
            let delivered = self.deliveredSnapshot()
            let gap = expected - delivered
            if gap > Int(target / 2) {
                continuation.yield(AudioChunk(
                    channel: .microphone,
                    samples: [Float](repeating: 0, count: gap),
                    sampleRate: target,
                    timestamp: Double(delivered) / target
                ))
                self.addDelivered(gap)
            }
            continuation.yield(AudioChunk(
                channel: .microphone,
                samples: samples,
                sampleRate: target,
                timestamp: elapsed
            ))
            self.addDelivered(samples.count)
        }
    }

    /// A configuration change means the engine stopped (device switched or
    /// disappeared). Reinstall and restart; if no usable input exists yet,
    /// retry shortly — when one returns, the tap's gap padding covers the
    /// downtime.
    private func scheduleRestart(delay: TimeInterval = 0) {
        restartQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.continuation != nil else { return }
            let input = self.engine.inputNode
            input.removeTap(onBus: 0)
            try? self.applyPinnedDeviceIfNeeded(required: false)
            guard input.outputFormat(forBus: 0).sampleRate > 0 else {
                self.scheduleRestart(delay: 0.5)
                return
            }
            self.installTap()
            self.engine.prepare()
            do {
                try self.engine.start()
            } catch {
                self.scheduleRestart(delay: 0.5)
            }
        }
    }

    /// Re-selects the pinned input device. `required` start fails hard on a
    /// missing device; a mid-recording restart falls back to the default
    /// input instead (the pinned device may be the one that vanished).
    private func applyPinnedDeviceIfNeeded(required: Bool) throws {
        #if os(macOS)
        guard let deviceIdentifier else { return }
        guard
            let device = try? AudioDeviceCatalog.inputDevice(matching: deviceIdentifier),
            let audioUnit = engine.inputNode.audioUnit
        else {
            if required { throw AudioCaptureError.noInputDevice }
            return
        }
        var deviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else {
            if required {
                throw AudioCaptureError.coreAudioError(
                    operation: "select input device '\(device.name)'",
                    status: status
                )
            }
            return
        }
        #endif
    }

    private func deliveredSnapshot() -> Int {
        deliveredLock.lock()
        defer { deliveredLock.unlock() }
        return samplesDelivered
    }

    private func addDelivered(_ count: Int) {
        deliveredLock.lock()
        defer { deliveredLock.unlock() }
        samplesDelivered += count
    }
}
