import Foundation
import PortavozCore

/// Per-channel, bounded handoff from real-time capture to optional live speech
/// consumers. The producer never suspends. When a model attaches after a cold
/// load it receives only the newest context, not an unbounded meeting backlog;
/// finalized audio remains the complete source of truth after Stop.
public final class BoundedLiveAudioFeeds: Sendable {
    private let streams: [AudioChannel: AsyncStream<AudioChunk>]
    private let continuations: [AudioChannel: AsyncStream<AudioChunk>.Continuation]

    public init(channels: [AudioChannel], capacityPerChannel: Int = 128) {
        precondition(capacityPerChannel > 0)
        var streams: [AudioChannel: AsyncStream<AudioChunk>] = [:]
        var continuations: [AudioChannel: AsyncStream<AudioChunk>.Continuation] = [:]
        for channel in Set(channels) {
            let pair = AsyncStream.makeStream(
                of: AudioChunk.self,
                bufferingPolicy: .bufferingNewest(capacityPerChannel))
            streams[channel] = pair.stream
            continuations[channel] = pair.continuation
        }
        self.streams = streams
        self.continuations = continuations
    }

    public func stream(for channel: AudioChannel) -> AsyncStream<AudioChunk>? {
        streams[channel]
    }

    public func yield(_ chunk: AudioChunk) {
        continuations[chunk.channel]?.yield(chunk)
    }

    public func finish() {
        for continuation in continuations.values {
            continuation.finish()
        }
    }
}
