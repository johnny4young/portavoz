import AudioToolbox
import AVFAudio
import Foundation
import PortavozCore
import os

enum AudioInputFormatPolicy {
    static func isUsable(sampleRate: Double, channelCount: AVAudioChannelCount) -> Bool {
        CapturePCMGeometry.isUsable(sampleRate: sampleRate) && channelCount > 0
    }

    static func isUsable(_ format: AVAudioFormat) -> Bool {
        isUsable(sampleRate: format.sampleRate, channelCount: format.channelCount)
    }
}

/// Input taps observe the hardware route instead of attempting to configure it.
///
/// A route can change between reading `outputFormat` and installing a tap.
/// Passing that earlier format back to AVFAudio can therefore raise an
/// Objective-C format-mismatch exception. A nil requested format leaves the
/// bus untouched; each delivered buffer is then resampled from its actual rate.
enum AudioInputTapPolicy {
    static var requestedFormat: AVAudioFormat? {
        nil
    }

    static func sourceSampleRate(for bufferFormat: AVAudioFormat) -> Double? {
        guard AudioInputFormatPolicy.isUsable(bufferFormat) else {
            return nil
        }
        return bufferFormat.sampleRate
    }
}

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
///
/// Raw capture is the default. Apple's voice-processing IO changes both the
/// input and output graph and may duck other audio, so meeting and dictation
/// surfaces must opt in only when they explicitly own that trade-off.
///
/// `@unchecked Sendable`: the engine and continuation are mutated only from
/// `start()`/`stop()` and the serial `restartQueue`; the tap block runs
/// serialized on the render thread and closes over its own continuation.
public final class MicrophoneSource: CaptureReportingSource, @unchecked Sendable {
    public let channel: AudioChannel = .microphone

    private var engine = AVAudioEngine()
    private let clock = HostClock()
    private let deviceIdentifier: String?
    private let voiceProcessing: Bool
    private let restartQueue = DispatchQueue(label: "app.portavoz.mic-restart")
    private let delivery = CaptureDeliveryBuffer(channel: .microphone)
    private var continuation: CaptureDeliveryBuffer?
    private let failureHandler = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    public var captureReport: CaptureChannelReport { delivery.report() }

    public func setCaptureFailureHandler(_ handler: @escaping @Sendable () -> Void) {
        failureHandler.withLock { $0 = handler }
    }

    private func observeDeliveryFailure() {
        delivery.setFailureHandler { [weak self] in
            guard let self else { return }
            self.failureHandler.withLock { $0 }?()
            // Never mutate the hardware graph from its realtime callback.
            self.restartQueue.async { [weak self] in self?.teardown() }
        }
    }
    private var observer: (any NSObjectProtocol)?
    private var tapInstalled = false
    private var routeTransitions = AudioRouteTransitionGate()
    /// Rate of the first device; the stream promises this rate for its whole
    /// life, so replacement devices get resampled to it. Written once.
    private var streamSampleRate: Double = 0
    /// Total samples yielded so far, for gap accounting after a device
    /// change. Touched from the render thread and the restart queue.
    private let deliveredLock = NSLock()
    private var samplesDelivered = 0
    /// When muted, the tap yields silence instead of the captured samples —
    /// so Portavoz stops recording/transcribing YOUR voice while the meeting
    /// app keeps its own mic (this mutes the app, not the system input). The
    /// file stays timeline-aligned because silence is still written.
    private let muteLock = NSLock()
    private var muted = false

    /// Mute or unmute the mic for Portavoz only. Thread-safe; takes effect on
    /// the next buffer.
    public func setMuted(_ value: Bool) {
        muteLock.lock()
        muted = value
        muteLock.unlock()
    }

    private var isMuted: Bool {
        muteLock.lock()
        defer { muteLock.unlock() }
        return muted
    }

    /// - Parameters:
    ///   - deviceIdentifier: UID or name of the input device to use (macOS).
    ///     Nil uses the system default input.
    ///   - voiceProcessing: explicitly enables Apple's echo cancellation.
    ///     It is off by default because voice-processing IO also changes the
    ///     output path and can interfere with an active call.
    public init(deviceIdentifier: String? = nil, voiceProcessing: Bool = false) {
        self.deviceIdentifier = deviceIdentifier
        self.voiceProcessing = voiceProcessing
    }

    /// Starts the engine WITHOUT a tap while the caller prepares the rest of
    /// its pipeline. Yields no chunks and the session clock still anchors at
    /// the first real tap callback. Explicit voice-processing clients also
    /// use this time for their adaptive filter to converge. Safe to skip —
    /// `start()` does the full setup itself when the engine isn't warm.
    public func warmUp() async {
        restartQueue.sync {
            guard delivery.isAccepting, continuation == nil, !engine.isRunning else { return }
            try? applyPinnedDeviceIfNeeded(required: false)
            applyVoiceProcessingIfEnabled()
            // AVAudioEngine.prepare() can raise an Objective-C exception
            // instead of a Swift error when the current input route has no
            // hardware format. Fail closed and let start() surface the typed
            // no-input-device failure once the user actually starts capture.
            guard AudioInputFormatPolicy.isUsable(
                engine.inputNode.outputFormat(forBus: 0)
            ) else {
                return
            }
            engine.prepare()
            try? engine.start()
        }
    }

    public func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        try restartQueue.sync {
            guard delivery.isAccepting, continuation == nil else {
                throw CaptureDeliveryFailure(cause: .sourceFailed)
            }
            let input = engine.inputNode
            if !engine.isRunning {
                // Cold start; a warm engine already has device policy applied.
                try applyPinnedDeviceIfNeeded(required: true)
                applyVoiceProcessingIfEnabled()
            }

            let format = input.outputFormat(forBus: 0)
            guard AudioInputFormatPolicy.isUsable(format) else {
                throw AudioCaptureError.noInputDevice
            }

            observeDeliveryFailure()
            let stream = delivery.stream()
            let continuation = delivery
            self.continuation = continuation
            streamSampleRate = format.sampleRate
            routeTransitions.activate()
            installTap()

            if !engine.isRunning {
                engine.prepare()
                do {
                    try engine.start()
                } catch {
                    teardown()
                    throw error
                }
            }
            installConfigurationObserver()
            return stream
        }
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
        routeTransitions.deactivate()
        discardCurrentEngine()
        continuation?.finish()
        continuation = nil
        failureHandler.withLock { $0 = nil }
    }

    /// Stops and detaches the current graph without ending the capture stream.
    /// Must run on `restartQueue`.
    private func discardCurrentEngine() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func installConfigurationObserver() {
        let observedEngine = engine
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: observedEngine,
            queue: nil
        ) { [weak self] _ in
            self?.requestRestart()
        }
    }

    /// Installs the tap at the CURRENT device format, resampling to the
    /// stream's original rate when they differ, and padding any capture gap
    /// (device switch downtime) with silence to keep the timeline aligned.
    private func installTap() {
        let input = engine.inputNode
        let target = streamSampleRate
        guard
            target.isFinite,
            target > 0,
            let continuation
        else {
            return
        }

        let clock = clock
        input.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: AudioInputTapPolicy.requestedFormat
        ) { [weak self] buffer, when in
            guard let self, continuation.isAccepting else { return }
            guard let native = AudioInputTapPolicy.sourceSampleRate(
                for: buffer.format
            ) else {
                return
            }
            var samples: [Float]
            let elapsed: TimeInterval
            let plan: CapturePCMGeometry.Delivery
            do {
                samples = try Downmix.mono(from: buffer) { frames in
                    try continuation.admitNativeFrames(frames, sourceRate: native, targetRate: target)
                }
                guard !samples.isEmpty else { return }
                elapsed = clock.elapsed(hostTime: when.hostTime)
                // Local mute preserves the raw file's timeline, not the call's input.
                if self.isMuted { samples = [Float](repeating: 0, count: samples.count) }
                if native != target { samples = try Resample.linear(samples, from: native, to: target) }
                plan = try CapturePCMGeometry.delivery(
                    elapsed: elapsed, sampleRate: target,
                    delivered: self.deliveredSnapshot(), incoming: samples.count)
            } catch Downmix.InputError.unavailable {
                // Disabled native input keeps its stream/route recovery alive.
                return
            } catch let failure as CaptureDeliveryFailure {
                continuation.finish(failure: failure.cause)
                return
            } catch {
                continuation.finish(failure: .invalidFormat)
                return
            }
            if continuation.append(samples: samples, rate: target, timestamp: elapsed, plan: plan) {
                self.setDelivered(plan.deliveredFrameCount)
            }
        }
        tapInstalled = true
    }

    /// A configuration change means the engine stopped (device switched or
    /// disappeared). The notification is delivered on AVFAudio's internal
    /// queue, so only enqueue a generation-fenced handoff here. A fresh engine
    /// owns exactly one tap and avoids AVFAudio's process-terminating
    /// "one tap per bus" precondition when route notifications arrive in a
    /// burst. Gap padding covers the handoff downtime.
    private func requestRestart() {
        restartQueue.async { [weak self] in
            guard let self, let ticket = self.routeTransitions.request() else {
                return
            }
            self.scheduleRestart(
                ticket: ticket,
                delay: AudioRouteTransitionTiming.settleDelay
            )
        }
    }

    private func scheduleRestart(
        ticket: AudioRouteTransitionGate.Ticket,
        delay: TimeInterval
    ) {
        restartQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard
                let self,
                self.continuation != nil,
                self.routeTransitions.admits(ticket)
            else {
                return
            }

            self.discardCurrentEngine()
            self.engine = AVAudioEngine()
            try? self.applyPinnedDeviceIfNeeded(required: false)
            self.applyVoiceProcessingIfEnabled()
            let input = self.engine.inputNode
            guard AudioInputFormatPolicy.isUsable(input.outputFormat(forBus: 0)) else {
                self.scheduleRestart(
                    ticket: ticket,
                    delay: AudioRouteTransitionTiming.retryDelay
                )
                return
            }
            self.installTap()
            self.engine.prepare()
            do {
                try self.engine.start()
                self.installConfigurationObserver()
            } catch {
                self.discardCurrentEngine()
                self.scheduleRestart(
                    ticket: ticket,
                    delay: AudioRouteTransitionTiming.retryDelay
                )
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

    private func setDelivered(_ count: Int) {
        deliveredLock.lock()
        defer { deliveredLock.unlock() }
        samplesDelivered = count
    }
}
