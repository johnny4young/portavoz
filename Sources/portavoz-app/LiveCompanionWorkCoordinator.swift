import IntelligenceKit

/// Owns live Apuntador generation for one recording lifecycle.
///
/// A question already being answered is allowed to finish. While it runs,
/// only the newest not-yet-started candidate is retained, matching the
/// detector's latest-wins contract without creating one wrapper task per turn.
/// Cancellation discards pending material, fences the active result, and keeps
/// a newly submitted candidate behind the winding-down task.
@MainActor
final class LiveCompanionWorkCoordinator {
    typealias Generator = @MainActor @Sendable (
        CompanionGenerationRequest
    ) async -> CompanionGenerationResult
    typealias Receiver = @MainActor @Sendable (
        CompanionGenerationRequest,
        CompanionGenerationResult
    ) -> Void

    private let generator: Generator
    private let receiver: Receiver
    private var worker: Task<Void, Never>?
    private var pending: CompanionGenerationRequest?

    init(
        generator: @escaping Generator,
        receiver: @escaping Receiver
    ) {
        self.generator = generator
        self.receiver = receiver
    }

    var isRunning: Bool { worker != nil }
    var hasPendingWork: Bool { pending != nil }

    func submit(_ request: CompanionGenerationRequest) {
        pending = request
        startWorkerIfNeeded()
    }

    func cancel() {
        pending = nil
        worker?.cancel()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, pending != nil else { return }
        worker = Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !Task.isCancelled, let request = pending {
            pending = nil
            let result = await generator(request)
            guard !Task.isCancelled else { break }
            receiver(request, result)
        }

        worker = nil
        // A request may arrive after cancellation while the prior generator
        // is still unwinding. It waits behind that operation, then starts on
        // a fresh, non-cancelled task here.
        startWorkerIfNeeded()
    }
}
