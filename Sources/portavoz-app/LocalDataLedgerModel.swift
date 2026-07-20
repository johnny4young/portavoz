import ApplicationKit
import Observation

@MainActor
protocol LocalDataLedgerModelClient: AnyObject {
    func loadLocalDataLedger() async throws -> LocalDataLedgerSnapshot
}

/// Process-scoped owner for a truthful local-data receipt. An unavailable field
/// never replaces its healthy peers with a false zero.
@MainActor
@Observable
final class LocalDataLedgerModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded(LocalDataLedgerSnapshot)
    }

    private(set) var phase: Phase = .idle
    private let client: any LocalDataLedgerModelClient
    private var lastSnapshot: LocalDataLedgerSnapshot?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(client: any LocalDataLedgerModelClient) {
        self.client = client
    }

    var snapshot: LocalDataLedgerSnapshot? {
        if case .loaded(let snapshot) = phase { return snapshot }
        return lastSnapshot
    }

    func load() async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        defer { loadTask = nil }
        let previous = phase
        phase = .loading
        do {
            let snapshot = try await client.loadLocalDataLedger()
            lastSnapshot = snapshot
            phase = .loaded(snapshot)
        } catch is CancellationError {
            phase = previous
        } catch {
            let snapshot = LocalDataLedgerSnapshot(
                audioBytes: nil,
                meetingCount: nil,
                voiceCount: nil)
            lastSnapshot = snapshot
            phase = .loaded(snapshot)
        }
    }
}
