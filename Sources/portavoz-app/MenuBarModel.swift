import ApplicationKit
import Foundation
import Observation
import PortavozCore

/// Narrow composition contract for the resident menu-bar surface. GRDB and
/// EventKit mechanics stay behind the app adapter.
@MainActor
protocol MenuBarModelClient: AnyObject {
    func observeMenuBar() -> AsyncStream<MenuBarUpdate>
    func nextMenuBarEvent() async -> UpcomingEvent?
    func menuBarBriefOffer(
        for event: UpcomingEvent
    ) async -> PreMeetingBriefOffer?
    func prepareMenuBarBrief(
        for event: UpcomingEvent
    ) async -> MeetingBrief?
    func performMenuBarBriefSkill(
        proposalID: UUID,
        offer: PreMeetingBriefOffer,
        approvedBrief: MeetingBrief
    ) async throws -> String?
    func dismissMenuBarBriefOffer(_ offer: PreMeetingBriefOffer) async throws
}

/// Presentation owner for the resident macOS surface. SwiftUI renders one
/// private-write snapshot and never coordinates persistence or calendar work.
@MainActor
@Observable
final class MenuBarModel {
    struct BriefConfirmTarget: Identifiable {
        let proposalID: UUID
        let offer: PreMeetingBriefOffer
        let brief: MeetingBrief

        var id: UUID { proposalID }
    }

    struct BriefPreparationRequest: Identifiable {
        let id = UUID()
        let offer: PreMeetingBriefOffer
    }

    enum BriefConfirmationResult: Equatable {
        case succeeded
        case failed(String)
    }

    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case degraded(failures: Int)
        case failed
    }

    struct State {
        fileprivate(set) var loadPhase: LoadPhase = .idle
        fileprivate(set) var meetings: [MenuBarMeeting] = []
        fileprivate(set) var pendingByMeeting: [MeetingID: Int] = [:]
        fileprivate(set) var nextEvent: UpcomingEvent?
        fileprivate(set) var briefOffer: PreMeetingBriefOffer?
        fileprivate(set) var briefPreparationRequest: BriefPreparationRequest?
        fileprivate(set) var briefConfirmTarget: BriefConfirmTarget?
        fileprivate(set) var preparedBrief: MeetingBrief?
        fileprivate(set) var preparedEventID: String?
        fileprivate(set) var briefFailure: String?
    }

    private(set) var state = State()

    private let client: any MenuBarModelClient
    private var observationID = UUID()
    private var observedSections: Set<MenuBarReadSection> = []
    private var failedSections: Set<MenuBarReadSection> = []

    init(client: any MenuBarModelClient) {
        self.client = client
    }

    func observe() async {
        let currentObservationID = UUID()
        observationID = currentObservationID
        observedSections = []
        failedSections = []
        state.loadPhase = .loading
        let nextEvent = await client.nextMenuBarEvent()
        guard !Task.isCancelled,
              observationID == currentObservationID
        else { return }
        let briefOffer: PreMeetingBriefOffer? = if let nextEvent {
            await client.menuBarBriefOffer(for: nextEvent)
        } else {
            nil
        }
        guard !Task.isCancelled,
              observationID == currentObservationID
        else { return }
        state.nextEvent = nextEvent
        state.briefOffer = briefOffer

        for await update in client.observeMenuBar() {
            guard !Task.isCancelled, observationID == currentObservationID else { return }
            publish(update)
        }
    }

    func requestBrief(_ offer: PreMeetingBriefOffer) {
        guard state.briefPreparationRequest == nil,
              state.briefConfirmTarget == nil,
              state.preparedBrief == nil,
              state.briefOffer?.id == offer.id
        else { return }
        state.briefFailure = nil
        state.briefPreparationRequest = BriefPreparationRequest(offer: offer)
    }

    func prepareRequestedBrief() async {
        guard let request = state.briefPreparationRequest else { return }
        let brief = await client.prepareMenuBarBrief(for: request.offer.event)
        guard !Task.isCancelled,
              state.briefPreparationRequest?.id == request.id
        else { return }
        state.briefPreparationRequest = nil
        guard let brief else {
            state.briefFailure = L10n.text(
                "The brief could not be prepared. Nothing ran.")
            return
        }
        state.briefConfirmTarget = BriefConfirmTarget(
            proposalID: UUID(),
            offer: request.offer,
            brief: brief)
    }

    func confirmBrief(
        _ target: BriefConfirmTarget
    ) async -> BriefConfirmationResult {
        do {
            let failure = try await client.performMenuBarBriefSkill(
                proposalID: target.proposalID,
                offer: target.offer,
                approvedBrief: target.brief)
            guard !Task.isCancelled,
                  state.briefConfirmTarget?.proposalID == target.proposalID
            else {
                return .failed(L10n.text("The brief was cancelled. Nothing ran."))
            }
            guard let failure else {
                state.briefConfirmTarget = nil
                state.briefOffer = nil
                state.preparedBrief = target.brief
                state.preparedEventID = target.offer.event.id
                return .succeeded
            }
            return .failed(failure)
        } catch is CancellationError {
            return .failed(L10n.text("The brief was cancelled. Nothing ran."))
        } catch {
            return .failed(L10n.text(
                "The brief could not be prepared. Nothing ran."))
        }
    }

    func cancelBriefConfirmation() {
        state.briefConfirmTarget = nil
    }

    func closePreparedBrief() {
        state.preparedBrief = nil
    }

    func dismissBriefOffer(_ offer: PreMeetingBriefOffer) async {
        do {
            try await client.dismissMenuBarBriefOffer(offer)
            guard state.briefOffer?.id == offer.id else { return }
            state.briefOffer = nil
            state.briefFailure = nil
        } catch is CancellationError {
            return
        } catch {
            state.briefFailure = L10n.text(
                "The brief suggestion could not be dismissed.")
        }
    }
}

private extension MenuBarModel {
    func publish(_ update: MenuBarUpdate) {
        switch update {
        case .meetings(let meetings):
            state.meetings = meetings
            markObserved(.meetings)
        case .pendingCounts(let counts):
            state.pendingByMeeting = counts
            markObserved(.pendingCounts)
        case .failed(let section):
            failedSections.insert(section)
        }
        refreshLoadPhase()
    }

    func markObserved(_ section: MenuBarReadSection) {
        observedSections.insert(section)
        failedSections.remove(section)
    }

    func refreshLoadPhase() {
        let accounted = observedSections.union(failedSections)
        guard accounted.count == MenuBarReadSection.allCases.count else {
            state.loadPhase = .loading
            return
        }
        guard failedSections.count < MenuBarReadSection.allCases.count else {
            state.loadPhase = .failed
            return
        }
        if !failedSections.isEmpty {
            state.loadPhase = .degraded(failures: failedSections.count)
            return
        }
        state.loadPhase = state.meetings.isEmpty && state.nextEvent == nil
            ? .empty
            : .loaded
    }
}
