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
/// `@unchecked Sendable`: Core Audio object IDs are plain integers; mutable
/// state is owned by `start()`/`stop()` and the serialized IO queue.
@available(macOS 14.4, *)
public final class ProcessTapSource: AudioCaptureSource, @unchecked Sendable {
    public let channel: AudioChannel = .system

    private let processIDs: [pid_t]
    private let ioQueue = DispatchQueue(label: "app.portavoz.tap-io")
    private let clock = HostClock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?

    /// - Parameter processIDs: PIDs whose output to capture. Empty captures
    ///   every process (global tap) — prefer per-app taps in product code.
    public init(processIDs: [pid_t] = []) {
        self.processIDs = processIDs
    }

    public func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        do {
            let description: CATapDescription
            if processIDs.isEmpty {
                description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            } else {
                let objects = try processIDs.map(Self.processObject(for:))
                description = CATapDescription(stereoMixdownOfProcesses: objects)
            }
            description.isPrivate = true
            description.muteBehavior = .unmuted

            var tap = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
            tapID = tap

            let format = try Self.tapStreamFormat(tapID: tap)

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Portavoz Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                        kAudioSubTapDriftCompensationKey: true,
                    ]
                ],
            ]
            var aggregate = AudioObjectID(kAudioObjectUnknown)
            try check(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate),
                "AudioHardwareCreateAggregateDevice"
            )
            aggregateID = aggregate

            let (stream, continuation) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
            self.continuation = continuation

            let sampleRate = format.mSampleRate
            let clock = clock
            var procID: AudioDeviceIOProcID?
            let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, ioQueue) { _, inputData, inputTime, _, _ in
                let samples = Downmix.mono(fromBufferList: inputData, format: format)
                guard !samples.isEmpty else { return }
                continuation.yield(AudioChunk(
                    channel: .system,
                    samples: samples,
                    sampleRate: sampleRate,
                    timestamp: clock.elapsed(hostTime: inputTime.pointee.mHostTime)
                ))
            }
            try check(status, "AudioDeviceCreateIOProcIDWithBlock")
            ioProcID = procID
            try check(AudioDeviceStart(aggregate, procID), "AudioDeviceStart")

            return stream
        } catch {
            // Core Audio setup is multi-step; any throw after creating a tap,
            // aggregate device, continuation, or IOProc must release the
            // partial graph before the caller retries.
            await stop()
            throw error
        }
    }

    public func stop() async {
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
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Core Audio plumbing

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw AudioCaptureError.coreAudioError(operation: operation, status: status)
        }
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
