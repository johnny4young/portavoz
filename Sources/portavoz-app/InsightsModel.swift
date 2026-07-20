import ApplicationKit
import Foundation
import Observation
import PortavozCore

/// Narrow composition contract for the Insights feature. Storage projections
/// and GRDB observation mechanics stay behind the app adapter.
@MainActor
protocol InsightsModelClient: AnyObject {
    func observeInsights(
        scope: InsightsScope,
        now: Date
    ) -> AsyncStream<InsightsUpdate>
}

/// Per-window owner of Insights loading, partial failure, scope, and one
/// storage-independent read-model snapshot.
@MainActor
@Observable
final class InsightsModel {
    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case degraded(failures: Int)
        case failed
    }

    struct State {
        fileprivate(set) var phase: LoadPhase = .idle
        fileprivate(set) var scope: InsightsScope = .week
        fileprivate(set) var readModel: InsightsReadModel?
    }

    private(set) var state = State()

    private let client: any InsightsModelClient
    private let clock: @MainActor () -> Date
    private var referenceDate = Date()
    private var observationID = UUID()
    private var observedSections: Set<InsightsSection> = []
    private var failedSections: Set<InsightsSection> = []
    private var hasMeetingSnapshot = false
    private var meetings: [Meeting] = []
    private var facts: InsightsLibraryFacts?
    private var balance: InsightsVoiceBalance?
    private var findingInputs: [MeetingID: InsightsFindingInput] = [:]

    init(
        client: any InsightsModelClient,
        clock: @escaping @MainActor () -> Date = Date.init
    ) {
        self.client = client
        self.clock = clock
    }

    func observe(scope: InsightsScope) async {
        let currentID = UUID()
        observationID = currentID
        referenceDate = clock()
        state.scope = scope
        state.phase = .loading
        observedSections = []
        failedSections = []
        refreshReadModel()

        for await update in client.observeInsights(scope: scope, now: referenceDate) {
            guard !Task.isCancelled, observationID == currentID else { return }
            publish(update)
        }
    }
}

private extension InsightsModel {
    func publish(_ update: InsightsUpdate) {
        switch update {
        case .meetings(let value):
            meetings = value
            hasMeetingSnapshot = true
            markObserved(.meetings)
        case .facts(let value):
            facts = value
            markObserved(.facts)
        case .voiceBalance(let value):
            balance = value
            markObserved(.voiceBalance)
        case .findingInputs(let value):
            findingInputs = value
            markObserved(.findings)
        case .failed(let section):
            failedSections.insert(section)
            observedSections.remove(section)
            if section == .meetings, !hasMeetingSnapshot {
                hasMeetingSnapshot = true
                meetings = []
            }
        }
        refreshReadModel()
        refreshPhase()
    }

    func markObserved(_ section: InsightsSection) {
        observedSections.insert(section)
        failedSections.remove(section)
    }

    func refreshReadModel() {
        guard hasMeetingSnapshot else { return }
        state.readModel = InsightsReadModel.compute(
            meetings: meetings,
            facts: facts,
            balance: balance,
            findingInputs: findingInputs,
            scope: state.scope,
            now: referenceDate)
    }

    func refreshPhase() {
        let accountedSections = observedSections.union(failedSections)
        guard accountedSections.count == InsightsSection.allCases.count else {
            state.phase = .loading
            return
        }
        guard failedSections.count < InsightsSection.allCases.count else {
            state.phase = .failed
            return
        }
        if !failedSections.isEmpty {
            state.phase = .degraded(failures: failedSections.count)
            return
        }
        state.phase = meetings.isEmpty ? .empty : .loaded
    }
}
