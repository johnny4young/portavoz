#if os(macOS)
import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation
import PortavozCore

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
public final class ProcessTapSource: RecoverableAudioCaptureSource, @unchecked Sendable {
    public let channel: AudioChannel = .system

    private let processIDs: [pid_t]
    private let ioQueue = DispatchQueue(label: "app.portavoz.tap-io")
    private let rebuildQueue = DispatchQueue(label: "app.portavoz.tap-rebuild")
    private let clock = HostClock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    private var outputListener: AudioObjectPropertyListenerBlock?
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
        let (stream, continuation) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
        self.continuation = continuation
        do {
            try buildGraph()
        } catch {
            // Core Audio setup is multi-step; any throw after creating a tap,
            // aggregate device, or IOProc must release the partial graph
            // before the caller retries.
            await stop()
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
            guard let self else { return }
            var samples = Downmix.mono(fromBufferList: inputData, format: format)
            guard !samples.isEmpty else { return }
            if nativeRate != targetRate, nativeRate > 0, targetRate > 0 {
                samples = Resample.linear(samples, from: nativeRate, to: targetRate)
            }
            let elapsed = clock.elapsed(hostTime: inputTime.pointee.mHostTime)
            // Pad the output-switch downtime with silence so the system file
            // stays aligned with wall-clock (and the mic channel).
            let expected = Int(elapsed * targetRate)
            let delivered = self.deliveredSnapshot()
            let gap = expected - delivered
            if gap > Int(targetRate / 2) {
                continuation.yield(AudioChunk(
                    channel: .system,
                    samples: [Float](repeating: 0, count: gap),
                    sampleRate: targetRate,
                    timestamp: Double(delivered) / targetRate
                ))
                self.addDelivered(gap)
            }
            continuation.yield(AudioChunk(
                channel: .system,
                samples: samples,
                sampleRate: targetRate,
                timestamp: elapsed
            ))
            self.addDelivered(samples.count)
        }
        try check(status, "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = procID
        try check(AudioDeviceStart(aggregate, procID), "AudioDeviceStart")
    }

    /// Rebuilds the tap graph on the new default output. Runs serialized so a
    /// burst of change notifications can't race; retries shortly if the new
    /// device isn't ready yet.
    private func rebuild(delay: TimeInterval = 0) {
        rebuildQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.continuation != nil else { return }
            self.destroyGraph()
            do {
                try self.buildGraph()
            } catch {
                self.rebuild(delay: 0.5)
            }
        }
    }

    /// Best-effort recovery requested after the writer observes that this tap
    /// stopped delivering frames while the microphone remains alive. The
    /// serialized rebuild queue preserves the current stream and its timeline.
    public func requestRecovery() async {
        rebuild()
    }

    private func installOutputDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuild()
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
        removeOutputDeviceListener()
        destroyGraph()
        continuation?.finish()
        continuation = nil
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

    private func addDelivered(_ count: Int) {
        deliveredLock.lock()
        defer { deliveredLock.unlock() }
        samplesDelivered += count
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
