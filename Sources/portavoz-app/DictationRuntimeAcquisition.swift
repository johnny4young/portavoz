import Foundation

/// Session-owned model acquisition that runs beside microphone capture. Its
/// lease is always adopted or finished, including one that resolves after
/// the session was cancelled.
@MainActor
final class DictationRuntimeAcquisition {
    private let acquire: () async throws -> LiveTranscriptionRuntime
    private var task: Task<LiveTranscriptionRuntime, Error>?
    private var adopted: LiveTranscriptionRuntime?

    init(acquire: @escaping () async throws -> LiveTranscriptionRuntime) {
        self.acquire = acquire
    }

    func start() {
        guard task == nil else { return }
        let acquire = acquire
        task = Task { try await acquire() }
    }

    /// Cancelling the waiting session also cancels the load request.
    func runtime() async throws -> LiveTranscriptionRuntime {
        start()
        guard let task else { throw CancellationError() }
        let runtime = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        adopted = runtime
        return runtime
    }

    /// Ends the claim only after any in-flight load actually returns, so
    /// capture admission keeps covering a cancelled cold preparation.
    func settle() async {
        if let adopted {
            self.adopted = nil
            adopted.finish()
            return
        }
        guard let task else { return }
        self.task = nil
        task.cancel()
        if let late = try? await task.value { late.finish() }
    }
}
