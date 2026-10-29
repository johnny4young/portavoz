import Foundation

/// Per-frame microphone energy split into what the loudspeaker echo explains
/// and what it does not. A range whose energy is almost all echo was the
/// remote side heard through the speakers, not the person at the microphone.
public struct MicrophoneEchoProfile: Equatable, Sendable {
    public let frameDuration: TimeInterval
    public let microphoneEnergy: [Float]
    public let nearEndEnergy: [Float]

    public init(
        frameDuration: TimeInterval,
        microphoneEnergy: [Float],
        nearEndEnergy: [Float]
    ) {
        precondition(frameDuration > 0)
        precondition(microphoneEnergy.count == nearEndEnergy.count)
        self.frameDuration = frameDuration
        self.microphoneEnergy = microphoneEnergy
        self.nearEndEnergy = nearEndEnergy
    }

    /// Decibels of microphone energy explained by speaker echo over a time
    /// range, or nil when the full range is not measured or holds no microphone signal.
    public func echoAttenuationDB(from start: TimeInterval, to end: TimeInterval) -> Double? {
        guard start >= 0, end > start, !microphoneEnergy.isEmpty,
            end <= Double(microphoneEnergy.count) * frameDuration
        else { return nil }
        let first = Int((start / frameDuration).rounded(.down))
        let last = min(microphoneEnergy.count, Int((end / frameDuration).rounded(.up)))
        guard first < last else { return nil }
        var microphone = 0.0
        var nearEnd = 0.0
        for index in first..<last {
            microphone += Double(microphoneEnergy[index])
            nearEnd += Double(nearEndEnergy[index])
        }
        guard microphone > 0 else { return nil }
        return 10 * log10(microphone / max(nearEnd, microphone * 1e-6))
    }
}
