import PortavozCore

/// Bounded transport only. The controller's callbacks retain session identity,
/// presentation and delivery authority; this task never touches those states.
func makeDictationAudioPump(
    stream: AsyncThrowingStream<AudioChunk, Error>,
    feed: AsyncStream<AudioChunk>.Continuation,
    onLevel: @escaping @MainActor @Sendable (Float) -> Void,
    onFailure: @escaping @MainActor @Sendable () -> Void
) -> Task<Void, Never> {
    Task.detached {
        defer { feed.finish() }
        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                switch feed.yield(chunk) {
                case .enqueued: break
                case .dropped, .terminated:
                    if !Task.isCancelled { await onFailure() }
                    return
                @unknown default:
                    if !Task.isCancelled { await onFailure() }
                    return
                }
                let peak = chunk.samples.reduce(Float(0)) { max($0, abs($1)) }
                await onLevel(peak)
            }
        } catch {
            // An upstream CancellationError is not our user's Cancel.
            if !Task.isCancelled { await onFailure() }
        }
    }
}
