import Foundation
import Observation

/// One ordered owner survives tab reconstruction. A failed change stays at the
/// head until an explicit retry/discard; Stop closes audio first, then drains it.
@MainActor
@Observable
final class RecordingInputPersistence {
    private(set) var isSaving = false
    private(set) var hasFailure = false
    private(set) var retainedText = ""
    @ObservationIgnored private var pending: [Change] = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    private struct Change {
        let text: String
        let operation: @MainActor () async throws -> Void
    }

    func enqueue(text: String = "", operation: @escaping @MainActor () async throws -> Void) {
        guard !hasFailure else { return }
        pending.append(Change(text: text, operation: operation))
        start()
    }

    func drain() async {
        await worker?.value
    }

    func retry() {
        guard hasFailure else { return }
        hasFailure = false
        start()
    }

    func discardFailedChange() {
        guard hasFailure else { return }
        pending.removeFirst()
        hasFailure = false
        retainedText = ""
        start()
    }

    private func start() {
        guard worker == nil, !hasFailure, !pending.isEmpty else { return }
        isSaving = true
        worker = Task {
            while let change = pending.first {
                do {
                    try await change.operation()
                    pending.removeFirst()
                } catch {
                    retainedText = change.text
                    hasFailure = true
                    break
                }
            }
            if !hasFailure { retainedText = "" }
            isSaving = false
            worker = nil
        }
    }
}
