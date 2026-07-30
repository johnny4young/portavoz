import Foundation
import PortavozCore

struct RecordingLevelSnapshot: Equatable, Sendable {
    var microphoneLevel: Float?
    var microphoneIsLow = false
    var hasSystemSamples = false
    var systemAudioIsMissing = false
}

/// Pure one-slot state machine behind the recording meter relay. Every raw
/// signal sample updates diagnostic state, while optional presentation retains
/// only the newest complete snapshot and requests at most one scheduled drain.
struct RecordingLevelBuffer {
    private(set) var pendingValueCount = 0
    private(set) var isDeliveryScheduled = false
    private(set) var acceptsSubmissions = true

    private var generation: UInt64 = 0
    private var snapshot = RecordingLevelSnapshot()
    private var smoothedMicrophoneLevel: Float = 0
    private var voicedMicrophoneLevel: Float = 0
    private var voicedMicrophoneChunks = 0
    private var smoothedSystemRMS: Float = 0
    private var systemChunks = 0

    mutating func submit(_ sample: PersistedAudioLevel) -> UInt64? {
        guard acceptsSubmissions else { return nil }
        switch sample.channel {
        case .microphone:
            smoothedMicrophoneLevel = max(
                sample.peak,
                smoothedMicrophoneLevel * 0.8)
            snapshot.microphoneLevel = smoothedMicrophoneLevel
            if sample.peak > 0.004 {
                voicedMicrophoneLevel =
                    voicedMicrophoneLevel * 0.97 + sample.peak * 0.03
                voicedMicrophoneChunks += 1
            }
            snapshot.microphoneIsLow =
                voicedMicrophoneChunks > 150
                    && voicedMicrophoneLevel < 0.03
        case .system:
            systemChunks += 1
            smoothedSystemRMS =
                smoothedSystemRMS * 0.98 + sample.rms * 0.02
            snapshot.hasSystemSamples = true
            snapshot.systemAudioIsMissing =
                systemChunks > 500 && smoothedSystemRMS < 0.003
        case .room:
            return nil
        }

        pendingValueCount = 1
        guard !isDeliveryScheduled else { return nil }
        isDeliveryScheduled = true
        return generation
    }

    mutating func drain(generation expectedGeneration: UInt64)
        -> RecordingLevelSnapshot? {
        guard expectedGeneration == generation,
              isDeliveryScheduled
        else { return nil }

        isDeliveryScheduled = false
        guard pendingValueCount == 1 else { return nil }
        pendingValueCount = 0
        return snapshot
    }

    mutating func cancel() {
        generation &+= 1
        acceptsSubmissions = false
        pendingValueCount = 0
        isDeliveryScheduled = false
        snapshot = RecordingLevelSnapshot()
        smoothedMicrophoneLevel = 0
        voicedMicrophoneLevel = 0
        voicedMicrophoneChunks = 0
        smoothedSystemRMS = 0
        systemChunks = 0
    }
}

/// Thread-safe producer boundary for high-rate persisted signal evidence.
/// Submission performs bounded O(1) work and never suspends; delivery reaches
/// MainActor at display cadence with one latest-value slot.
final class RecordingLevelRelay: @unchecked Sendable {
    typealias Delivery =
        @MainActor @Sendable (RecordingLevelSnapshot) -> Void

    private let lock = NSLock()
    private let cadence: Duration
    private let delivery: Delivery
    private var buffer = RecordingLevelBuffer()

    init(
        cadence: Duration = .milliseconds(50),
        delivery: @escaping Delivery
    ) {
        self.cadence = cadence
        self.delivery = delivery
    }

    func submit(_ sample: PersistedAudioLevel) {
        lock.lock()
        let generation = buffer.submit(sample)
        lock.unlock()
        guard let generation else { return }

        let cadence = cadence
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: cadence)
            } catch {
                return
            }
            self?.deliver(generation: generation)
        }
    }

    func cancel() {
        lock.lock()
        buffer.cancel()
        lock.unlock()
    }

    @MainActor
    private func deliver(generation: UInt64) {
        lock.lock()
        let snapshot = buffer.drain(generation: generation)
        lock.unlock()
        if let snapshot {
            delivery(snapshot)
        }
    }
}
