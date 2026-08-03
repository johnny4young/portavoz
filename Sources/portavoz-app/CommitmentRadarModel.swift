import ApplicationKit
import Foundation
import Observation
import PortavozCore

/// Narrow composition contract for the global confirmed-commitment surface.
/// SwiftUI never constructs the read use case or reaches StorageKit directly.
@MainActor
protocol CommitmentRadarModelClient: AnyObject {
    func loadCommitmentRadar(
        _ request: LoadCommitmentRadarRequest
    ) async throws -> CommitmentRadarPage

    func mutateCommitmentRadar(
        _ request: ManageCommitmentRadarRequest
    ) async throws
}

@MainActor
@Observable
final class CommitmentRadarModel {
    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case failed
    }

    enum OwnerSelection: String, CaseIterable, Identifiable {
        case all
        case mine
        case others
        case unassigned

        var id: String { rawValue }

        var filter: CommitmentRadarOwnerFilter {
            switch self {
            case .all: .all
            case .mine: .mine
            case .others: .others
            case .unassigned: .unassigned
            }
        }
    }

    enum DueSelection: String, CaseIterable, Identifiable {
        case all
        case dueSoon
        case overdue
        case noDate

        var id: String { rawValue }

        var filter: CommitmentRadarDueFilter {
            switch self {
            case .all: .all
            case .dueSoon: .dueSoon
            case .overdue: .overdue
            case .noDate: .noDate
            }
        }
    }

    enum ActivitySelection: String, CaseIterable, Identifiable {
        case all
        case new
        case unchanged
        case completed
        case reopened

        var id: String { rawValue }

        var filter: CommitmentRadarActivityFilter {
            switch self {
            case .all: .all
            case .new: .activity(.new)
            case .unchanged: .activity(.unchanged)
            case .completed: .activity(.completed)
            case .reopened: .activity(.reopened)
            }
        }
    }

    enum Grouping: String, CaseIterable, Identifiable {
        case owner
        case meeting

        var id: String { rawValue }
    }

    struct State {
        fileprivate(set) var phase: LoadPhase = .idle
        fileprivate(set) var owner: OwnerSelection = .all
        fileprivate(set) var due: DueSelection = .all
        fileprivate(set) var activity: ActivitySelection = .all
        fileprivate(set) var grouping: Grouping = .owner
        fileprivate(set) var page: CommitmentRadarPage?
        fileprivate(set) var mutatingCommitmentID: CommitmentID?
        fileprivate(set) var mutationFailed = false
    }

    enum Action {
        case load
        case ownerChanged(OwnerSelection)
        case dueChanged(DueSelection)
        case activityChanged(ActivitySelection)
        case groupingChanged(Grouping)
        case complete(CommitmentID)
        case reopen(CommitmentID)
        case reschedule(CommitmentID, Date?)
        case dismissMutationFailure
    }

    private(set) var state = State()

    private let client: any CommitmentRadarModelClient
    private var requestID = UUID()

    init(client: any CommitmentRadarModelClient) {
        self.client = client
    }

    func send(_ action: Action) async {
        switch action {
        case .load:
            await load()
        case .ownerChanged(let owner):
            state.owner = owner
            await load()
        case .dueChanged(let due):
            state.due = due
            await load()
        case .activityChanged(let activity):
            state.activity = activity
            await load()
        case .groupingChanged(let grouping):
            state.grouping = grouping
        case .complete(let commitmentID):
            await mutate(commitmentID, mutation: .complete)
        case .reopen(let commitmentID):
            await mutate(commitmentID, mutation: .reopen)
        case .reschedule(let commitmentID, let dueAt):
            await mutate(commitmentID, mutation: .reschedule(dueAt))
        case .dismissMutationFailure:
            state.mutationFailed = false
        }
    }
}

private extension CommitmentRadarModel {
    func load(showProgress: Bool = true) async {
        let currentRequestID = UUID()
        requestID = currentRequestID
        if showProgress { state.phase = .loading }
        do {
            let page = try await client.loadCommitmentRadar(LoadCommitmentRadarRequest(
                owner: state.owner.filter,
                due: state.due.filter,
                activity: state.activity.filter))
            guard requestID == currentRequestID, !Task.isCancelled else { return }
            state.page = page
            state.phase = page.items.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            // A newer route/filter task owns presentation now.
        } catch {
            guard requestID == currentRequestID, !Task.isCancelled else { return }
            state.page = nil
            state.phase = .failed
        }
    }

    func mutate(
        _ commitmentID: CommitmentID,
        mutation: CommitmentRadarMutation
    ) async {
        guard state.mutatingCommitmentID == nil else { return }
        state.mutatingCommitmentID = commitmentID
        state.mutationFailed = false
        defer { state.mutatingCommitmentID = nil }
        do {
            try await client.mutateCommitmentRadar(ManageCommitmentRadarRequest(
                commitmentID: commitmentID,
                mutation: mutation))
            await load(showProgress: false)
        } catch is CancellationError {
            // Route teardown owns cancellation; no failure banner is useful.
        } catch {
            state.mutationFailed = true
        }
    }
}
