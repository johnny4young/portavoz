import Foundation

/// One cancellable deadline per existing runtime group, not a new model owner.
/// The release adapters still arbitrate real residency through their leases.
@MainActor
final class AppModelIdleReleaseScheduler {
    enum Slot: CaseIterable, Sendable {
        case recording, quality, language

        /// Lightweight keeps a short grace so dictation bursts, the Stop to
        /// post-capture handoff and follow-up questions reuse hot weights.
        func idleDelay(for profile: AppModelMemoryPreferences.Profile) -> Duration {
            switch (profile, self) {
            case (.balanced, .recording): .seconds(600)
            case (.balanced, _): .seconds(120)
            case (.lightweight, .recording): .seconds(60)
            case (.lightweight, _): .seconds(30)
            }
        }
    }

    typealias Sleep = @Sendable (Duration) async throws -> Void
    private struct Job {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let sleep: Sleep
    private var jobs: [Slot: Job] = [:]
    var pendingCount: Int { jobs.count }

    init(sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    deinit { for job in jobs.values { job.task.cancel() } }

    func cancel(_ slot: Slot) {
        jobs.removeValue(forKey: slot)?.task.cancel()
    }

    func cancelAll() {
        for slot in Slot.allCases { cancel(slot) }
    }

    func schedule(
        _ slot: Slot,
        profile: AppModelMemoryPreferences.Profile,
        release: @escaping @MainActor @Sendable () async -> Void
    ) {
        cancel(slot)
        let id = UUID()
        let sleep = sleep
        let task = Task { @MainActor [weak self] in
            defer { self?.finish(slot, id: id) }
            do {
                try Task.checkCancellation()
                guard self?.jobs[slot]?.id == id else { return }
                try await sleep(slot.idleDelay(for: profile))
                try Task.checkCancellation()
                guard self?.jobs[slot]?.id == id else { return }
                await release()
            } catch {
                // Cancellation or a failed clock cannot authorize a release.
                return
            }
        }
        jobs[slot] = Job(id: id, task: task)
    }

    private func finish(_ slot: Slot, id: UUID) {
        guard jobs[slot]?.id == id else { return }
        jobs[slot] = nil
    }
}
