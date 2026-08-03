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

    func recordCommitmentFieldPresentation(
        _ request: RecordCommitmentFieldPresentationRequest
    ) async throws

    func loadCommitmentFieldQuality() async throws -> CommitmentFieldQualityScorecard
}

@MainActor
@Observable
final class CommitmentRadarModel {
    enum Mode: String, CaseIterable, Identifiable {
        case confirmed
        case review
        case quality

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
        fileprivate(set) var recordedPresentationIDs: Set<UUID> = []
        fileprivate(set) var qualityPhase: LoadPhase = .idle
        fileprivate(set) var qualityScorecard: CommitmentFieldQualityScorecard?
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
        case reviewCandidatePresented(meetingID: MeetingID, actionItemID: UUID)
    }

    private(set) var state = State()

    private let client: any CommitmentRadarModelClient
    private var radarRequestID = UUID()
    private var reviewRequestID = UUID()
    private var qualityRequestID = UUID()
    private var presentationTasks: [UUID: Task<Bool, Never>] = [:]

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
            radarRequestID = UUID()
            reviewRequestID = UUID()
            qualityRequestID = UUID()
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
                meetingID: meetingID,
                request: .dismiss(
                    meetingID: meetingID,
                    actionItemID: actionItemID))
        case .deferReview(let meetingID, let actionItemID, let revisitAt):
            await mutateReview(
                actionItemID,
                meetingID: meetingID,
                request: .deferUntil(
                    meetingID: meetingID,
                    actionItemID: actionItemID,
                    revisitAt: revisitAt))
        case .dismissReviewMutationFailure:
            state.reviewMutationFailed = false
        case .reviewCandidatePresented(let meetingID, let actionItemID):
            await recordPresentation(
                meetingID: meetingID,
                actionItemID: actionItemID)
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
        case .quality:
            await loadFieldQuality()
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
            guard radarRequestID == currentRequestID,
                  state.mode == .confirmed,
                  !Task.isCancelled
            else { return }
            state.page = page
            state.phase = page.items.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            // A newer route/filter task owns presentation now.
        } catch {
            guard radarRequestID == currentRequestID,
                  state.mode == .confirmed,
                  !Task.isCancelled
            else { return }
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
            guard reviewRequestID == currentRequestID,
                  state.mode == .review,
                  !Task.isCancelled
            else {
                return
            }
            state.recordedPresentationIDs.formIntersection(page.items.map(\.id))
            state.reviewPage = page
            state.reviewPhase = page.items.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            // A newer route or mode task owns presentation now.
        } catch {
            guard reviewRequestID == currentRequestID,
                  state.mode == .review,
                  !Task.isCancelled
            else {
                return
            }
            state.reviewPage = nil
            state.reviewPhase = .failed
        }
    }

    func mutateReview(
        _ actionItemID: UUID,
        meetingID: MeetingID,
        request: ReviewMeetingCommitmentRequest
    ) async {
        guard state.reviewingActionItemID == nil else { return }
        state.reviewingActionItemID = actionItemID
        state.reviewMutationFailed = false
        defer { state.reviewingActionItemID = nil }
        do {
            await recordPresentation(
                meetingID: meetingID,
                actionItemID: actionItemID)
            try await client.reviewMeetingCommitment(request)
            await loadReviewQueue(showProgress: false)
        } catch is CancellationError {
            // Route teardown owns cancellation; no failure banner is useful.
        } catch {
            state.reviewMutationFailed = true
        }
    }

    func recordPresentation(
        meetingID: MeetingID,
        actionItemID: UUID
    ) async {
        guard reviewContains(actionItemID),
              !state.recordedPresentationIDs.contains(actionItemID)
        else { return }
        if let task = presentationTasks[actionItemID] {
            if await task.value, reviewContains(actionItemID) {
                state.recordedPresentationIDs.insert(actionItemID)
            }
            return
        }

        let task = Task { [client] in
            do {
                try await client.recordCommitmentFieldPresentation(
                    RecordCommitmentFieldPresentationRequest(
                        meetingID: meetingID,
                        actionItemID: actionItemID))
                return true
            } catch {
                return false
            }
        }
        presentationTasks[actionItemID] = task
        let succeeded = await task.value
        presentationTasks[actionItemID] = nil
        if succeeded, reviewContains(actionItemID) {
            state.recordedPresentationIDs.insert(actionItemID)
        }
    }

    func reviewContains(_ actionItemID: UUID) -> Bool {
        state.reviewPage?.items.contains(where: { $0.id == actionItemID }) == true
    }

    func loadFieldQuality(showProgress: Bool = true) async {
        let currentRequestID = UUID()
        qualityRequestID = currentRequestID
        if showProgress { state.qualityPhase = .loading }
        do {
            let scorecard = try await client.loadCommitmentFieldQuality()
            guard qualityRequestID == currentRequestID,
                  state.mode == .quality,
                  !Task.isCancelled
            else {
                return
            }
            state.qualityScorecard = scorecard
            state.qualityPhase = scorecard.overall.observationCount == 0
                ? .empty
                : .loaded
        } catch is CancellationError {
            // A newer route owns presentation now.
        } catch {
            guard qualityRequestID == currentRequestID,
                  state.mode == .quality,
                  !Task.isCancelled
            else {
                return
            }
            state.qualityScorecard = nil
            state.qualityPhase = .failed
        }
    }
}
