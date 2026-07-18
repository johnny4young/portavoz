import ApplicationKit
import Foundation
import Observation
import PortavozCore

/// Narrow composition contract for the resident menu-bar surface. GRDB and
/// EventKit mechanics stay behind the app adapter.
@MainActor
protocol MenuBarModelClient: AnyObject {
    func observeMenuBar() -> AsyncStream<MenuBarUpdate>
    func nextMenuBarEvent() -> UpcomingEvent?
}

/// Presentation owner for the resident macOS surface. SwiftUI renders one
/// private-write snapshot and never coordinates persistence or calendar work.
@MainActor
@Observable
final class MenuBarModel {
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
        state.nextEvent = client.nextMenuBarEvent()

        for await update in client.observeMenuBar() {
            guard !Task.isCancelled, observationID == currentObservationID else { return }
            publish(update)
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
