import Foundation

/// One identity-fenced countdown that closes a delivery or failure notice.
/// A newer schedule or a cancel makes any earlier expiry a no-op.
@MainActor
final class DictationFeedbackTimer {
    private var task: Task<Void, Never>?
    private var id: UUID?

    var isCounting: Bool { task != nil }

    func schedule(
        after delay: Duration,
        wait: @escaping @MainActor (Duration) async throws -> Void,
        expire: @escaping @MainActor () -> Void
    ) {
        cancel()
        let id = UUID()
        self.id = id
        task = Task { [weak self] in
            do {
                try await wait(delay)
            } catch {
                return
            }
            guard let self, self.id == id, !Task.isCancelled else { return }
            self.id = nil
            self.task = nil
            expire()
        }
    }

    func cancel() {
        id = nil
        task?.cancel()
        task = nil
    }
}
