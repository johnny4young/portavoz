import AudioToolbox
import AVFAudio
import Foundation
import PortavozCore

/// Captures the local microphone through AVAudioEngine at the device's
/// native format, downmixed to mono. Recording keeps native quality;
/// resampling for STT is TranscriptionKit's job.
///
/// `@unchecked Sendable`: the engine is mutated only from `start()`/`stop()`
/// (single owner) and the tap block runs serialized on the render thread.
public final class MicrophoneSource: AudioCaptureSource, @unchecked Sendable {
    public let channel: AudioChannel = .microphone

    private let engine = AVAudioEngine()
    private let clock = HostClock()
    private let deviceIdentifier: String?
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?

    /// - Parameter deviceIdentifier: UID or name of the input device to use
    ///   (macOS). Nil uses the system default input.
    public init(deviceIdentifier: String? = nil) {
        self.deviceIdentifier = deviceIdentifier
    }

    public func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        let input = engine.inputNode

        #if os(macOS)
        if let deviceIdentifier {
            guard let device = try AudioDeviceCatalog.inputDevice(matching: deviceIdentifier) else {
                throw AudioCaptureError.noInputDevice
            }
            guard let audioUnit = input.audioUnit else {
                throw AudioCaptureError.noInputDevice
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
                throw AudioCaptureError.coreAudioError(
                    operation: "select input device '\(device.name)'",
                    status: status
                )
            }
        }
        #endif
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        let (stream, continuation) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
        self.continuation = continuation

        let sampleRate = format.sampleRate
        let clock = clock
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            let samples = Downmix.mono(from: buffer)
            guard !samples.isEmpty else { return }
            continuation.yield(AudioChunk(
                channel: .microphone,
                samples: samples,
                sampleRate: sampleRate,
                timestamp: clock.elapsed(hostTime: when.hostTime)
            ))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.continuation = nil
            throw error
        }
        return stream
    }

    public func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}
