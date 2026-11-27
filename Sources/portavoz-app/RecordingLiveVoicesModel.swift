import ApplicationKit
import Foundation
import Observation

/// The recording's live voices: turns, columns, ticks and cast. Its own
/// observation boundary, rebuilt at most once a second and never per level
/// sample, so only views that draw voices re-render and the recording bar
/// never re-measures for them.
@MainActor
@Observable
final class RecordingLiveVoicesModel {
    typealias Now = @MainActor () -> ContinuousClock.Instant
    typealias Sleep = @Sendable (Duration) async throws -> Void

    static let minimumInterval: Duration = .seconds(1)
    private static let emptyCast = VoiceCast(members: [], ordering: .recency)

    private(set) var stage = LiveVoiceStage.empty
    private(set) var cast = emptyCast

    @ObservationIgnored private(set) var youSpeaking = false
    @ObservationIgnored private var source: (@MainActor () -> LiveVoiceSource?)?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh: ContinuousClock.Instant?
    @ObservationIgnored private let now: Now
    @ObservationIgnored private let sleep: Sleep

    init(
        now: @escaping Now = { ContinuousClock.now },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    /// Where refreshes read from; nil while nothing is recording.
    func connect(_ source: @escaping @MainActor () -> LiveVoiceSource?) {
        self.source = source
    }

    /// Only a flip asks for a refresh; repeated level deliveries do nothing.
    func setYouSpeaking(_ value: Bool) {
        guard value != youSpeaking else { return }
        youSpeaking = value
        requestRefresh()
    }

    /// Coalesces every request into one refresh, a second after the last.
    func requestRefresh() {
        guard pending == nil, source != nil else { return }
        let delay = Self.delay(since: lastRefresh, now: now())
        let sleep = sleep
        pending = Task { [weak self] in
            if delay > .zero {
                do { try await sleep(delay) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func apply(_ source: LiveVoiceSource) {
        let next = LiveVoiceStage.updating(stage, with: source)
        guard next != stage else { return }
        stage = next
        let nextCast = next.cast(previous: cast)
        if nextCast != cast { cast = nextCast }
    }

    func reset() {
        pending?.cancel()
        expiry?.cancel()
        (pending, expiry, lastRefresh) = (nil, nil, nil)
        youSpeaking = false
        if stage != .empty { stage = .empty }
        if cast != Self.emptyCast { cast = Self.emptyCast }
    }

    static func delay(since last: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Duration {
        guard let last else { return .zero }
        return max(.zero, minimumInterval - (now - last))
    }

    private func refresh() {
        pending = nil
        expiry?.cancel()
        expiry = nil
        lastRefresh = now()
        guard var source = source?() else { return }
        source.youSpeaking = youSpeaking
        apply(source)
        // Without the gate, whoever owns the open row (your microphone row
        // included) stops being current once that row goes quiet.
        guard stage.current != nil, !youSpeaking else { return }
        let sleep = sleep
        expiry = Task { [weak self] in
            do { try await sleep(.seconds(LiveVoiceStage.currentWindow) + Self.minimumInterval) } catch { return }
            self?.requestRefresh()
        }
    }
}
