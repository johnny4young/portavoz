import Foundation
import os
import PortavozCore

/// One bounded queue, not an AsyncStream queue followed by another queue.
/// Producers never await the file writer. Overflow closes admission, retires
/// hardware off IO, and leaves every admitted packet available to the consumer.
final class CaptureDeliveryBuffer: Sendable {
    struct Limits: Sendable {
        let frames: Int
        let packets: Int
        let chunkFrames: Int
        // 4 MiB PCM/channel, at most 256 packet descriptors. At 48 kHz and
        // 4096-frame callbacks this holds about 21.8 s of stalled writing.
        static let production = Limits(frames: 1_048_576, packets: 256, chunkFrames: 4096)
    }

    private struct Packet: Sendable {
        let samples: [Float]
        let sampleRate: Double
        let timestamp: TimeInterval
        let paddingTimestamp: TimeInterval
        let padding: Int
        var paddingOffset = 0
        var offset = 0
    }

    private struct State: Sendable {
        var ring: [Packet?]
        var head = 0
        var count = 0
        var retainedFrames = 0
        var peakFrames = 0
        var peakPackets = 0
        var accepted: Int64 = 0
        var padding: Int64 = 0
        var rejected: Int64? = 0
        var finished = false
        var nextInProgress = false
        var failure: CaptureFailure?
        var waiter: CheckedContinuation<Void, Never>?
        var onFailure: (@Sendable () -> Void)?
    }

    private enum Pull {
        case samples([Float], Range<Int>, Double, TimeInterval)
        case silence(Int, Double, TimeInterval)
        case finished(CaptureFailure?)
        case wait
    }

    let channel: AudioChannel
    let limits: Limits
    private let state: OSAllocatedUnfairLock<State>
    private let onConsumerWait: (@Sendable () -> Void)?

    init(
        channel: AudioChannel, limits: Limits = .production,
        onConsumerWait: (@Sendable () -> Void)? = nil
    ) {
        precondition(limits.frames > 0 && limits.packets > 0 && limits.chunkFrames > 0)
        self.channel = channel
        self.limits = limits
        self.onConsumerWait = onConsumerWait
        state = OSAllocatedUnfairLock(initialState: State(ring: Array(repeating: nil, count: limits.packets)))
    }

    /// Validate both transient arrays before downmix/resampling allocate them.
    func admitNativeFrames(_ frames: Int, sourceRate: Double, targetRate: Double) throws {
        let output = try CapturePCMGeometry.resampling(
            inputCount: frames, source: sourceRate, target: targetRate).frameCount
        let fits = state.withLock {
            !$0.finished && $0.count < limits.packets
                && frames <= limits.frames && output <= limits.frames - $0.retainedFrames
        }
        guard fits else {
            finish(failure: .overloaded, rejectedFrames: output)
            throw CaptureDeliveryFailure(cause: .overloaded)
        }
    }

    var isAccepting: Bool { state.withLock { !$0.finished } }
    var highWater: (frames: Int, packets: Int) { state.withLock { ($0.peakFrames, $0.peakPackets) } }

    func setFailureHandler(_ handler: @escaping @Sendable () -> Void) {
        let failed = state.withLock { state in
            state.onFailure = handler
            return state.failure != nil
        }
        if failed { handler() }
    }

    func report(writtenFrames: Int64? = nil, publicationFailed: Bool = false) -> CaptureChannelReport {
        state.withLock {
            CaptureChannelReport(
                channel: channel, acceptedFrames: $0.accepted, paddingFrames: $0.padding,
                rejectedFrames: $0.rejected, writtenFrames: writtenFrames,
                failure: $0.failure, publicationFailed: publicationFailed)
        }
    }

    /// The first rejected callback is evidence; later callbacks are not read.
    func finish(failure: CaptureFailure? = nil, rejectedFrames: Int? = nil) {
        let delivery = state.withLock { state -> (CheckedContinuation<Void, Never>?, (@Sendable () -> Void)?) in
            guard !state.finished else { return (nil, nil) }
            state.finished = true
            state.failure = failure
            state.rejected = failure == nil ? 0 : rejectedFrames.flatMap { $0 >= 0 ? Int64($0) : nil }
            let waiter = state.waiter
            state.waiter = nil
            return (waiter, failure == nil ? nil : state.onFailure)
        }
        delivery.0?.resume()
        delivery.1?()
    }

    @discardableResult
    func append(samples: [Float], rate: Double, timestamp: TimeInterval, plan: CapturePCMGeometry.Delivery) -> Bool {
        let result = state.withLock { state -> (Bool, CheckedContinuation<Void, Never>?) in
            guard !state.finished, state.count < limits.packets,
                  samples.count <= limits.frames - state.retainedFrames
            else { return (false, nil) }
            let (total, overflow) = state.accepted.addingReportingOverflow(
                Int64(samples.count) + Int64(plan.paddingFrameCount))
            guard !overflow else { return (false, nil) }
            let index = (state.head + state.count) % limits.packets
            state.ring[index] = Packet(
                samples: samples, sampleRate: rate, timestamp: timestamp,
                paddingTimestamp: plan.paddingTimestamp, padding: plan.paddingFrameCount)
            state.count += 1
            state.retainedFrames += samples.count
            state.peakFrames = max(state.peakFrames, state.retainedFrames)
            state.peakPackets = max(state.peakPackets, state.count)
            state.accepted = total
            state.padding += Int64(plan.paddingFrameCount)
            let waiter = state.waiter
            state.waiter = nil
            return (true, waiter)
        }
        result.1?.resume()
        if !result.0 { finish(failure: .overloaded, rejectedFrames: samples.count) }
        return result.0
    }

    func stream() -> AsyncThrowingStream<AudioChunk, Error> {
        // Unfolding can discard its closure before the first poll on cancellation.
        // Its closure-owned lifetime therefore also owns producer retirement.
        let lifetime = ConsumerLifetime(buffer: self)
        return AsyncThrowingStream(unfolding: { try await lifetime.buffer.next() })
    }

    private final class ConsumerLifetime: Sendable {
        let buffer: CaptureDeliveryBuffer
        init(buffer: CaptureDeliveryBuffer) { self.buffer = buffer }
        deinit { buffer.finish(failure: .cancelled) }
    }

    private func next() async throws -> AudioChunk? {
        let admitted = state.withLock { state in
            guard !state.nextInProgress else { return false }
            state.nextInProgress = true
            return true
        }
        guard admitted else {
            finish(failure: .sourceFailed)
            throw CaptureDeliveryFailure(cause: .sourceFailed)
        }
        defer { state.withLock { $0.nextInProgress = false } }
        return try await withTaskCancellationHandler {
            while true {
                try Task.checkCancellation()
                switch pull() {
                case .samples(let samples, let range, let rate, let time):
                    return AudioChunk(
                        channel: channel, samples: range == samples.indices ? samples : Array(samples[range]),
                        sampleRate: rate, timestamp: time)
                case .silence(let count, let rate, let time):
                    return AudioChunk(
                        channel: channel, samples: Array(repeating: 0, count: count),
                        sampleRate: rate, timestamp: time)
                case .finished(let failure):
                    if failure == .cancelled { throw CancellationError() }
                    try Task.checkCancellation()
                    if let failure { throw CaptureDeliveryFailure(cause: failure) }
                    return nil
                case .wait:
                    await withCheckedContinuation { waiter in
                        let ready = state.withLock { state in
                            if state.finished || state.ring[state.head] != nil { return true }
                            state.waiter = waiter
                            return false
                        }
                        if ready { waiter.resume() } else { onConsumerWait?() }
                    }
                }
            }
        } onCancel: {
            self.finish(failure: .cancelled)
        }
    }

    private func pull() -> Pull {
        state.withLock { state in
            guard var packet = state.ring[state.head] else {
                return state.finished ? .finished(state.failure) : .wait
            }
            let result: Pull
            if packet.paddingOffset < packet.padding {
                let count = min(limits.chunkFrames, packet.padding - packet.paddingOffset)
                result = .silence(count, packet.sampleRate,
                                  packet.paddingTimestamp + Double(packet.paddingOffset) / packet.sampleRate)
                packet.paddingOffset += count
            } else {
                let end = min(packet.samples.count, packet.offset + limits.chunkFrames)
                result = .samples(packet.samples, packet.offset..<end, packet.sampleRate,
                                  packet.timestamp + Double(packet.offset) / packet.sampleRate)
                packet.offset = end
            }
            if packet.paddingOffset == packet.padding && packet.offset == packet.samples.count {
                state.ring[state.head] = nil
                state.head = (state.head + 1) % limits.packets
                state.count -= 1
                state.retainedFrames -= packet.samples.count
            } else {
                state.ring[state.head] = packet
            }
            return result
        }
    }
}

struct CaptureDeliveryFailure: Error, Sendable {
    let cause: CaptureFailure
}
