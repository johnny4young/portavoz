import Foundation
import PortavozCore

struct RecordingLevelSnapshot: Equatable, Sendable {
    var microphoneLevel: Float?
    var microphoneIsLow = false
    var hasSystemSamples = false
    var systemAudioIsMissing = false
    var systemAudioIsClipping = false
}

/// Constant-space detector for a hard-limited incoming channel. It measures
/// captured time rather than callback count so route-specific buffer sizes do
/// not change the policy. One isolated full-scale peak is ordinary speech
/// evidence, not a warning; sustained recent ceiling exposure indicates likely
/// distortion.
struct SustainedCeilingDetector {
    static let ceiling: Float = 0.999
    static let minimumObservedDuration: TimeInterval = 2
    static let enterExposureDuration: TimeInterval = 1
    static let exitExposureDuration: TimeInterval = 0.1
    static let maximumObservationDuration: TimeInterval = 0.25
    static let cleanDecayRate = 0.5
    private static let durationTolerance: TimeInterval = 1e-9

    private(set) var isClipping = false
    private var observedDuration: TimeInterval = 0
    private var ceilingExposureDuration: TimeInterval = 0

    mutating func observe(peak: Float, duration: TimeInterval) -> Bool {
        guard duration.isFinite, duration > 0 else {
            return isClipping
        }
        let boundedDuration = min(duration, Self.maximumObservationDuration)
        observedDuration = min(
            Self.minimumObservedDuration,
            observedDuration + boundedDuration)
        if peak >= Self.ceiling {
            ceilingExposureDuration = min(
                Self.minimumObservedDuration,
                ceilingExposureDuration + boundedDuration)
        } else {
            ceilingExposureDuration = max(
                0,
                ceilingExposureDuration
                    - boundedDuration * Self.cleanDecayRate)
        }

        guard observedDuration
            >= Self.minimumObservedDuration - Self.durationTolerance
        else {
            return false
        }
        if isClipping {
            isClipping =
                ceilingExposureDuration > Self.exitExposureDuration
        } else {
            isClipping =
                ceilingExposureDuration
                    >= Self.enterExposureDuration - Self.durationTolerance
        }
        return isClipping
    }
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
    private var systemCeilingDetector = SustainedCeilingDetector()

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
            snapshot.systemAudioIsClipping =
                systemCeilingDetector.observe(
                    peak: sample.peak,
                    duration: sample.duration)
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
        systemCeilingDetector = SustainedCeilingDetector()
    }
}

/// Thread-safe producer boundary for high-rate persisted signal evidence.
/// Submission performs bounded O(1) work and never suspends; delivery reaches
/// MainActor at display cadence with one latest-value slot.
final class RecordingLevelRelay: @unchecked Sendable {
    typealias Delivery =
        @MainActor @Sendable (RecordingLevelSnapshot) -> Void
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let lock = NSLock()
    private let cadence: Duration
    private let sleep: Sleep
    private let delivery: Delivery
    private var buffer = RecordingLevelBuffer()

    init(
        cadence: Duration = .milliseconds(50),
        sleep: @escaping Sleep = { duration in
            try await Task.sleep(for: duration)
        },
        delivery: @escaping Delivery
    ) {
        self.cadence = cadence
        self.sleep = sleep
        self.delivery = delivery
    }

    func submit(_ sample: PersistedAudioLevel) {
        lock.lock()
        let generation = buffer.submit(sample)
        lock.unlock()
        guard let generation else { return }

        let cadence = cadence
        let sleep = sleep
        Task { @MainActor [weak self] in
            do {
                try await sleep(cadence)
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
