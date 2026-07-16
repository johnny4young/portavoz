import ApplicationKit
import Foundation
import Observation
import PortavozCore

/// Narrow read-side contract for one Meeting Detail feature instance.
@MainActor
protocol MeetingDetailModelClient: AnyObject {
    func observeMeetingReview(
        _ meetingID: MeetingID
    ) -> AsyncStream<MeetingReviewUpdate>
}

/// Per-detail owner of scoped loading, partial failure, and the current
/// storage-independent meeting review projection.
@MainActor
@Observable
final class MeetingDetailModel {
    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case missing
        case degraded(failures: Int)
        case failed
    }

    struct State {
        fileprivate(set) var phase: LoadPhase = .idle
        fileprivate(set) var readModel: MeetingReviewReadModel?
        fileprivate(set) var revision = 0
    }

    private(set) var state = State()
    let meetingID: MeetingID

    private let client: any MeetingDetailModelClient
    private var observationID = UUID()
    private var observedSections: Set<MeetingReviewSection> = []
    private var failedSections: Set<MeetingReviewSection> = []
    private var hasCoreSnapshot = false
    private var core: MeetingReviewCore?
    private var summary: MeetingReviewSummary?
    private var companionCards: [CompanionCard] = []

    init(meetingID: MeetingID, client: any MeetingDetailModelClient) {
        self.meetingID = meetingID
        self.client = client
    }

    func observe() async {
        let currentID = UUID()
        observationID = currentID
        state.phase = .loading
        observedSections = []
        failedSections = []

        for await update in client.observeMeetingReview(meetingID) {
            guard !Task.isCancelled, observationID == currentID else { return }
            publish(update)
        }
    }
}

private extension MeetingDetailModel {
    func publish(_ update: MeetingReviewUpdate) {
        switch update {
        case .core(let value):
            core = value
            hasCoreSnapshot = true
            markObserved(.core)
        case .summary(let value):
            summary = value
            markObserved(.summary)
        case .companionCards(let value):
            companionCards = value
            markObserved(.companion)
        case .failed(let section):
            failedSections.insert(section)
            observedSections.remove(section)
            if section == .core, !hasCoreSnapshot {
                hasCoreSnapshot = true
                core = nil
            }
        }
        refreshReadModel()
        refreshPhase()
        state.revision += 1
    }

    func markObserved(_ section: MeetingReviewSection) {
        observedSections.insert(section)
        failedSections.remove(section)
    }

    func refreshReadModel() {
        guard let core else {
            state.readModel = nil
            return
        }
        state.readModel = MeetingReviewReadModel(
            core: core,
            summary: summary,
            companionCards: companionCards)
    }

    func refreshPhase() {
        let accountedSections = observedSections.union(failedSections)
        guard accountedSections.count == MeetingReviewSection.allCases.count else {
            state.phase = .loading
            return
        }
        if core == nil, observedSections.contains(.core) {
            state.phase = .missing
            return
        }
        guard failedSections.count < MeetingReviewSection.allCases.count,
            !(failedSections.contains(.core) && core == nil)
        else {
            state.phase = .failed
            return
        }
        if !failedSections.isEmpty {
            state.phase = .degraded(failures: failedSections.count)
            return
        }
        state.phase = .loaded
    }
}
