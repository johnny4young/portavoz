#if os(macOS)
import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation
import PortavozCore
import os

/// Captures the audio *output* of specific processes (or all of them) via a
/// Core Audio process tap on a private aggregate device (macOS 14.4+).
///
/// This is how Portavoz hears "the meeting" without a virtual driver: tap
/// only Zoom/Meet/Teams, so unrelated audio (music, notifications) never
/// contaminates the transcript. First use triggers the system's audio
/// recording permission prompt (`NSAudioCaptureUsageDescription` in app builds).
///
/// **Output-device changes mid-recording** (Mac speakers → headphones): the
/// tap/aggregate is bound to the default output at creation time and goes
/// silent when the user switches output. We listen for
/// `kAudioHardwarePropertyDefaultOutputDevice` and rebuild the graph on the
/// new output, keeping the SAME stream; the downtime is padded with silence
/// so the system channel stays aligned with the mic channel (mirrors
/// `MicrophoneSource`'s input-change resilience).
///
/// `@unchecked Sendable`: Core Audio object IDs are plain integers; mutable
/// state is owned by `start()`/`stop()` and the serialized IO/rebuild queues.
@available(macOS 14.4, *)
public final class ProcessTapSource: RecoverableAudioCaptureSource, CaptureReportingSource, @unchecked Sendable {
    public let channel: AudioChannel = .system

    private let processIDs: [pid_t]
    private let ioQueue = DispatchQueue(label: "app.portavoz.tap-io")
    private let rebuildQueue = DispatchQueue(label: "app.portavoz.tap-rebuild")
    private let clock = HostClock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let delivery = CaptureDeliveryBuffer(channel: .system)
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
            self.rebuildQueue.async { [weak self] in self?.stopOnRebuildQueue() }
        }
    }
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var routeTransitions = AudioRouteTransitionGate()
    /// Rate of the first graph; the stream promises this rate for its whole
    /// life, so a rebuild on a device with a different rate gets resampled.
    private var streamSampleRate: Double = 0
    /// Total samples yielded, for gap accounting after an output switch.
    /// Touched from the IO thread and the rebuild queue.
    private let deliveredLock = NSLock()
    private var samplesDelivered = 0

    /// - Parameter processIDs: PIDs whose output to capture. Empty captures
    ///   every process (global tap) — prefer per-app taps in product code.
    public init(processIDs: [pid_t] = []) {
        self.processIDs = processIDs
    }

    public func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        try await withCheckedThrowingContinuation { completion in
            rebuildQueue.async { [self] in
                do {
                    completion.resume(returning: try startOnRebuildQueue())
                } catch {
                    completion.resume(throwing: error)
                }
            }
        }
    }

    /// Owns every mutable Core Audio graph identifier on `rebuildQueue`.
    private func startOnRebuildQueue() throws -> AsyncThrowingStream<AudioChunk, Error> {
        guard delivery.isAccepting, continuation == nil else {
            throw CaptureDeliveryFailure(cause: .sourceFailed)
        }
        observeDeliveryFailure()
        let stream = delivery.stream()
        let continuation = delivery
        self.continuation = continuation
        routeTransitions.activate()
        do {
            try buildGraph()
        } catch {
            // Core Audio setup is multi-step; any throw after creating a tap,
            // aggregate device, or IOProc must release the partial graph
            // before the caller retries.
            routeTransitions.deactivate()
            removeOutputDeviceListener()
            destroyGraph()
            continuation.finish()
            self.continuation = nil
            throw error
        }
        installOutputDeviceListener()
        return stream
    }

    // Construye tap + aggregate device + IOProc de Core Audio; secuencia
    // long imperative sequence against the C API. Splitting remains technical debt.
    /// Creates the tap + aggregate + IOProc against the CURRENT default
    /// output and starts it, yielding into `self.continuation`. On the first
    /// build it pins `streamSampleRate`; later builds resample to it.
    private func buildGraph() throws { // swiftlint:disable:this function_body_length
        guard let continuation else { return }

        // Skip PIDs that don't resolve to an audio process object (a process
        // may have exited, or never produced audio); tap the rest as a
        // mixdown. If none resolve, fall back to the global tap rather than
        // failing the recording.
        let objects = processIDs.compactMap { try? Self.processObject(for: $0) }
        let description: CATapDescription
        if objects.isEmpty {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: objects)
        }
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap

        let format = try Self.tapStreamFormat(tapID: tap)
        guard CapturePCMGeometry.isUsable(sampleRate: format.mSampleRate), format.mChannelsPerFrame > 0 else {
            throw AudioCaptureError.unsupportedFormat
        }
        if streamSampleRate == 0 { streamSampleRate = format.mSampleRate }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Portavoz Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate),
            "AudioHardwareCreateAggregateDevice"
        )
        aggregateID = aggregate

        let nativeRate = format.mSampleRate
        let targetRate = streamSampleRate
        let clock = clock
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggregate, ioQueue
        ) { [weak self] _, inputData, inputTime, _, _ in
            guard let self, continuation.isAccepting else { return }
            var samples: [Float]
            let elapsed: TimeInterval
            // Pad the output-switch downtime with silence so the system file
            // stays aligned with wall-clock (and the mic channel).
            let plan: CapturePCMGeometry.Delivery
            do {
                samples = try Downmix.mono(fromBufferList: inputData, format: format) { frames in
                    try continuation.admitNativeFrames(frames, sourceRate: nativeRate, targetRate: targetRate)
                }
                guard !samples.isEmpty else { return }
                elapsed = clock.elapsed(hostTime: inputTime.pointee.mHostTime)
                if nativeRate != targetRate {
                    samples = try Resample.linear(samples, from: nativeRate, to: targetRate)
                }
                plan = try CapturePCMGeometry.delivery(
                    elapsed: elapsed, sampleRate: targetRate,
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
            if continuation.append(samples: samples, rate: targetRate, timestamp: elapsed, plan: plan) {
                self.setDelivered(plan.deliveredFrameCount)
            }
        }
        try check(status, "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = procID
        try check(AudioDeviceStart(aggregate, procID), "AudioDeviceStart")
    }

    /// Rebuilds the tap graph on the new default output. Runs serialized so a
    /// burst of change notifications can't race; retries shortly if the new
    /// device isn't ready yet.
    private func requestRebuild() {
        rebuildQueue.async { [weak self] in
            guard let self, let ticket = self.routeTransitions.request() else {
                return
            }
            self.scheduleRebuild(
                ticket: ticket,
                delay: AudioRouteTransitionTiming.settleDelay
            )
        }
    }

    private func scheduleRebuild(
        ticket: AudioRouteTransitionGate.Ticket,
        delay: TimeInterval
    ) {
        rebuildQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard
                let self,
                self.continuation != nil,
                self.routeTransitions.admits(ticket)
            else {
                return
            }
            self.destroyGraph()
            do {
                try self.buildGraph()
            } catch {
                self.destroyGraph()
                self.scheduleRebuild(
                    ticket: ticket,
                    delay: AudioRouteTransitionTiming.retryDelay
                )
            }
        }
    }

    /// Best-effort recovery requested after the writer observes that this tap
    /// stopped delivering frames while the microphone remains alive. The
    /// serialized rebuild queue preserves the current stream and its timeline.
    public func requestRecovery() async {
        requestRebuild()
    }

    private func installOutputDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.requestRebuild()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, rebuildQueue, listener)
        if status == noErr { outputListener = listener }
    }

    private func removeOutputDeviceListener() {
        guard let outputListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, rebuildQueue, outputListener)
        self.outputListener = nil
    }

    /// Tears down tap/aggregate/IOProc WITHOUT ending the stream — used
    /// between rebuilds so the consumer and file keep going.
    private func destroyGraph() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID = ioProcID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
    }

    public func stop() async {
        await withCheckedContinuation { completion in
            rebuildQueue.async { [self] in
                stopOnRebuildQueue()
                completion.resume()
            }
        }
    }

    private func stopOnRebuildQueue() {
        routeTransitions.deactivate()
        removeOutputDeviceListener()
        destroyGraph()
        continuation?.finish()
        continuation = nil
        failureHandler.withLock { $0 = nil }
    }

    // MARK: - Core Audio plumbing

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw AudioCaptureError.coreAudioError(operation: operation, status: status)
        }
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

    /// Translates a POSIX PID into the Core Audio process object that taps target.
    private static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                qualifierPointer,
                &size,
                &object
            )
        }
        guard status == noErr, object != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioCaptureError.processNotFound(pid)
        }
        return object
    }

    private static func tapStreamFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else {
            throw AudioCaptureError.coreAudioError(operation: "kAudioTapPropertyFormat", status: status)
        }
        return format
    }
}
#endif
