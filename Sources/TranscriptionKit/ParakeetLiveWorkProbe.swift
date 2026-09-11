import Foundation
import os
import PortavozCore

/// Counts observable adapter work, never transcript text, token identities or
/// opaque backend prediction/recovery attempts. Only explicit diagnostics opt in.
public struct ParakeetLiveWorkSample: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case completed, cancelled, failed }
    public let channel: AudioChannel?
    public let sampleRate: Double?
    public let inputChunks: Int
    public let inputFrames: Int
    public let rejectedBuffers: Int
    public let backendUpdates: Int
    public let backendTokens: Int
    public let backendTokenTimings: Int
    public let confirmedUpdates: Int
    public let updatesAfterFinishStarted: Int
    public let finishCalls: Int
    public let loadMilliseconds: Double
    public let feedMilliseconds: Double
    public let finishMilliseconds: Double
    public let updateDrainMilliseconds: Double
    public let cleanupMilliseconds: Double
    public let valid: Bool
    public let outcome: Outcome
}

/// One fixed-size, per-stream observation. The optional engine observer receives
/// just this terminal value; there is no process-global collector or per-chunk task.
final class ParakeetLiveWorkProbe: Sendable {
    enum Phase: Int { case load, feed, finish, updateDrain, cleanup }

    private struct State {
        var channel: AudioChannel?
        var sampleRate: Double?
        var inputChunks = 0
        var inputFrames = 0
        var rejectedBuffers = 0
        var backendUpdates = 0
        var backendTokens = 0
        var backendTokenTimings = 0
        var confirmedUpdates = 0
        var updatesAfterFinishStarted = 0
        var finishCalls = 0
        var loadMilliseconds = 0.0
        var feedMilliseconds = 0.0
        var finishMilliseconds = 0.0
        var updateDrainMilliseconds = 0.0
        var cleanupMilliseconds = 0.0
        var valid = true
        var phase: Phase = .load
        var phaseStarted: Duration
        var sealed = false
    }

    private let state: OSAllocatedUnfairLock<State>
    private let now: @Sendable () -> Duration

    init(now: (@Sendable () -> Duration)? = nil) {
        let origin = ContinuousClock.now
        let clock: @Sendable () -> Duration = now ?? { origin.duration(to: .now) }
        self.now = clock
        state = OSAllocatedUnfairLock(initialState: State(phaseStarted: clock()))
    }

    func input(frames: Int, sampleRate: Double, channel: AudioChannel, accepted: Bool) {
        state.withLock { value in
            guard !value.sealed else { return }
            guard frames >= 0, sampleRate.isFinite, sampleRate > 0 else {
                value.valid = false
                return
            }
            if let previous = value.channel, previous != channel { value.valid = false }
            if let previous = value.sampleRate, previous != sampleRate { value.valid = false }
            value.channel = value.channel ?? channel
            value.sampleRate = value.sampleRate ?? sampleRate
            if accepted {
                value.valid = Self.add(1, to: &value.inputChunks) && value.valid
                value.valid = Self.add(frames, to: &value.inputFrames) && value.valid
            } else {
                value.valid = Self.add(1, to: &value.rejectedBuffers) && value.valid
            }
        }
    }

    func update(tokens: Int, timings: Int, confirmed: Bool) {
        state.withLock { value in
            guard !value.sealed else { return }
            value.valid = Self.add(1, to: &value.backendUpdates) && value.valid
            value.valid = Self.add(tokens, to: &value.backendTokens) && value.valid
            value.valid = Self.add(timings, to: &value.backendTokenTimings) && value.valid
            if confirmed { value.valid = Self.add(1, to: &value.confirmedUpdates) && value.valid }
            if value.finishCalls > 0 {
                value.valid = Self.add(1, to: &value.updatesAfterFinishStarted) && value.valid
            }
        }
    }

    func begin(_ phase: Phase) {
        let instant = now()
        state.withLock { value in
            guard !value.sealed else { return }
            if phase.rawValue <= value.phase.rawValue { value.valid = false }
            Self.closePhase(&value, at: instant)
            value.phase = phase
            value.phaseStarted = instant
            if phase == .finish { value.valid = Self.add(1, to: &value.finishCalls) && value.valid }
        }
    }

    func finish(outcome: ParakeetLiveWorkSample.Outcome) -> ParakeetLiveWorkSample? {
        let instant = now()
        return state.withLock { value in
            guard !value.sealed else { return nil }
            Self.closePhase(&value, at: instant)
            if outcome == .completed && (value.phase != .cleanup || value.finishCalls != 1) {
                value.valid = false
            }
            value.sealed = true
            return ParakeetLiveWorkSample(
                channel: value.channel, sampleRate: value.sampleRate,
                inputChunks: value.inputChunks, inputFrames: value.inputFrames,
                rejectedBuffers: value.rejectedBuffers, backendUpdates: value.backendUpdates,
                backendTokens: value.backendTokens, backendTokenTimings: value.backendTokenTimings,
                confirmedUpdates: value.confirmedUpdates,
                updatesAfterFinishStarted: value.updatesAfterFinishStarted, finishCalls: value.finishCalls,
                loadMilliseconds: value.loadMilliseconds, feedMilliseconds: value.feedMilliseconds,
                finishMilliseconds: value.finishMilliseconds,
                updateDrainMilliseconds: value.updateDrainMilliseconds,
                cleanupMilliseconds: value.cleanupMilliseconds, valid: value.valid, outcome: outcome)
        }
    }

    private static func add(_ count: Int, to value: inout Int) -> Bool {
        guard count >= 0 else { return false }
        let sum = value.addingReportingOverflow(count)
        guard !sum.overflow else { return false }
        value = sum.partialValue
        return true
    }

    private static func closePhase(_ value: inout State, at instant: Duration) {
        let elapsed = instant - value.phaseStarted
        let parts = elapsed.components
        let milliseconds = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
        guard elapsed >= .zero, milliseconds.isFinite else {
            value.valid = false
            return
        }
        switch value.phase {
        case .load: value.loadMilliseconds += milliseconds
        case .feed: value.feedMilliseconds += milliseconds
        case .finish: value.finishMilliseconds += milliseconds
        case .updateDrain: value.updateDrainMilliseconds += milliseconds
        case .cleanup: value.cleanupMilliseconds += milliseconds
        }
    }
}
