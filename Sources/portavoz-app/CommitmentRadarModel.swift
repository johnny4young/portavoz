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

    func loadCommitmentReviewQueue(
        _ request: LoadCommitmentReviewQueueRequest
    ) async throws -> CommitmentReviewQueuePage

    func reviewMeetingCommitment(
        _ request: ReviewMeetingCommitmentRequest
    ) async throws
}

@MainActor
@Observable
final class CommitmentRadarModel {
    enum Mode: String, CaseIterable, Identifiable {
        case confirmed
        case review

        var id: String { rawValue }
    }

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
        fileprivate(set) var mode: Mode = .confirmed
        fileprivate(set) var phase: LoadPhase = .idle
        fileprivate(set) var owner: OwnerSelection = .all
        fileprivate(set) var due: DueSelection = .all
        fileprivate(set) var activity: ActivitySelection = .all
        fileprivate(set) var grouping: Grouping = .owner
        fileprivate(set) var page: CommitmentRadarPage?
        fileprivate(set) var mutatingCommitmentID: CommitmentID?
        fileprivate(set) var mutationFailed = false
        fileprivate(set) var reviewPhase: LoadPhase = .idle
        fileprivate(set) var reviewPage: CommitmentReviewQueuePage?
        fileprivate(set) var reviewingActionItemID: UUID?
        fileprivate(set) var reviewMutationFailed = false
    }

    enum Action {
        case load
        case modeChanged(Mode)
        case ownerChanged(OwnerSelection)
        case dueChanged(DueSelection)
        case activityChanged(ActivitySelection)
        case groupingChanged(Grouping)
        case complete(CommitmentID)
        case reopen(CommitmentID)
        case reschedule(CommitmentID, Date?)
        case dismissMutationFailure
        case dismissReview(meetingID: MeetingID, actionItemID: UUID)
        case deferReview(meetingID: MeetingID, actionItemID: UUID, revisitAt: Date)
        case dismissReviewMutationFailure
    }

    private(set) var state = State()

    private let client: any CommitmentRadarModelClient
    private var radarRequestID = UUID()
    private var reviewRequestID = UUID()

    init(client: any CommitmentRadarModelClient) {
        self.client = client
    }

    func send(_ action: Action) async {
        if await handleRouteAction(action) { return }
        if await handleConfirmedAction(action) { return }
        await handleReviewAction(action)
    }
}

private extension CommitmentRadarModel {
    func handleRouteAction(_ action: Action) async -> Bool {
        switch action {
        case .load:
            await loadCurrentMode()
            return true
        case .modeChanged(let mode):
            guard state.mode != mode else { return true }
            state.mode = mode
            await loadCurrentMode()
            return true
        default:
            return false
        }
    }

    func handleConfirmedAction(_ action: Action) async -> Bool {
        switch action {
        case .ownerChanged(let owner):
            state.owner = owner
            await loadRadar()
        case .dueChanged(let due):
            state.due = due
            await loadRadar()
        case .activityChanged(let activity):
            state.activity = activity
            await loadRadar()
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
        default:
            return false
        }
        return true
    }

    func handleReviewAction(_ action: Action) async {
        switch action {
        case .dismissReview(let meetingID, let actionItemID):
            await mutateReview(
                actionItemID,
                request: .dismiss(
                    meetingID: meetingID,
                    actionItemID: actionItemID))
        case .deferReview(let meetingID, let actionItemID, let revisitAt):
            await mutateReview(
                actionItemID,
                request: .deferUntil(
                    meetingID: meetingID,
                    actionItemID: actionItemID,
                    revisitAt: revisitAt))
        case .dismissReviewMutationFailure:
            state.reviewMutationFailed = false
        default:
            assertionFailure("Unhandled Commitment Radar action")
        }
    }
}

private extension CommitmentRadarModel {
    func loadCurrentMode() async {
        switch state.mode {
        case .confirmed:
            await loadRadar()
        case .review:
            await loadReviewQueue()
        }
    }

    func loadRadar(showProgress: Bool = true) async {
        let currentRequestID = UUID()
        radarRequestID = currentRequestID
        if showProgress { state.phase = .loading }
        do {
            let page = try await client.loadCommitmentRadar(LoadCommitmentRadarRequest(
                owner: state.owner.filter,
                due: state.due.filter,
                activity: state.activity.filter))
            guard radarRequestID == currentRequestID, !Task.isCancelled else { return }
            state.page = page
            state.phase = page.items.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            // A newer route/filter task owns presentation now.
        } catch {
            guard radarRequestID == currentRequestID, !Task.isCancelled else { return }
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
            await loadRadar(showProgress: false)
        } catch is CancellationError {
            // Route teardown owns cancellation; no failure banner is useful.
        } catch {
            state.mutationFailed = true
        }
    }

    func loadReviewQueue(showProgress: Bool = true) async {
        let currentRequestID = UUID()
        reviewRequestID = currentRequestID
        if showProgress { state.reviewPhase = .loading }
        do {
            let page = try await client.loadCommitmentReviewQueue(
                LoadCommitmentReviewQueueRequest())
            guard reviewRequestID == currentRequestID, !Task.isCancelled else {
                return
            }
            state.reviewPage = page
            state.reviewPhase = page.items.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            // A newer route or mode task owns presentation now.
        } catch {
            guard reviewRequestID == currentRequestID, !Task.isCancelled else {
                return
            }
            state.reviewPage = nil
            state.reviewPhase = .failed
        }
    }

    func mutateReview(
        _ actionItemID: UUID,
        request: ReviewMeetingCommitmentRequest
    ) async {
        guard state.reviewingActionItemID == nil else { return }
        state.reviewingActionItemID = actionItemID
        state.reviewMutationFailed = false
        defer { state.reviewingActionItemID = nil }
        do {
            try await client.reviewMeetingCommitment(request)
            await loadReviewQueue(showProgress: false)
        } catch is CancellationError {
            // Route teardown owns cancellation; no failure banner is useful.
        } catch {
            state.reviewMutationFailed = true
        }
    }
}
