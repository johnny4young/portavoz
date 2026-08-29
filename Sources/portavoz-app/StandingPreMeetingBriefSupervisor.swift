import ApplicationKit
import Foundation
import PortavozCore
import StorageKit

protocol StandingPreMeetingBriefEventSource:
    UpcomingEventResolving, Sendable {
    func upcomingStandingBriefEvents() async -> [UpcomingEvent]
    func standingBriefEventChanges() async -> AsyncStream<Void>
}

/// One signal-driven process owner for the bounded standing-rule action. It
/// serializes relaunch recovery before new events, schedules only the next
/// lead-window boundary, and never polls the calendar or SQLite.
actor StandingPreMeetingBriefSupervisor {
    private let store: MeetingStore
    private let preparer: any StandingPreMeetingBriefPreparing
    private let events: any StandingPreMeetingBriefEventSource
    private let captureState: AppResourceCaptureState
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    private var observationTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var needsReconciliation = false

    init(
        store: MeetingStore,
        preparer: any StandingPreMeetingBriefPreparing,
        events: any StandingPreMeetingBriefEventSource,
        captureState: AppResourceCaptureState,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.preparer = preparer
        self.events = events
        self.captureState = captureState
        self.calendar = calendar
        self.now = now
    }

    deinit {
        observationTask?.cancel()
        worker?.cancel()
        wakeTask?.cancel()
    }

    func start() async {
        guard observationTask == nil else { return }
        let changes = await events.standingBriefEventChanges()
        observationTask = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await self?.kick()
            }
        }
        kick()
    }

    func kick() {
        needsReconciliation = true
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    func suspendForCapture() {
        needsReconciliation = true
        worker?.cancel()
        cancelScheduledWake()
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        worker?.cancel()
        worker = nil
        cancelScheduledWake()
        needsReconciliation = false
    }

    private func drain() async {
        while needsReconciliation, !Task.isCancelled {
            needsReconciliation = false
            guard captureState.current == .inactive else { break }
            try? await reconcile()
        }
        worker = nil
        if needsReconciliation, captureState.current == .inactive {
            kick()
        }
    }

    private func reconcile() async throws {
        let snapshot = try await LoadStandingSkillRules(store: store).execute(())
        guard !snapshot.isPaused else {
            cancelScheduledWake()
            return
        }
        let activeRules = Dictionary(uniqueKeysWithValues: snapshot.rules
            .filter(\.isEffectivelyEnabled)
            .map { ($0.rule.id, $0.rule) })
        let pending = try await store.pendingStandingSkillExecutions(
            limit: StandingSkillExecutionPolicy.maximumPendingExecutionCount)
        let executor = makeExecutor()
        try await resumePending(
            pending,
            activeRules: activeRules,
            executor: executor)

        guard captureState.current == .inactive else {
            needsReconciliation = true
            return
        }
        try await prepareUpcoming(
            activeRules: activeRules,
            executor: executor)
    }

    private func resumePending(
        _ pending: [PendingStandingSkillExecution],
        activeRules: [StandingSkillRuleID: StandingSkillRule],
        executor: ExecuteStandingPreMeetingBrief
    ) async throws {
        for owner in pending {
            try Task.checkCancellation()
            guard captureState.current == .inactive else {
                needsReconciliation = true
                return
            }
            guard owner.record.state != .executing,
                  owner.record.attempt
                    < StandingSkillExecutionPolicy.maximumAutomaticAttempts,
                  activeRules[owner.ruleID] != nil
            else {
                await cancelConfirmedIfRevoked(owner)
                continue
            }
            guard let event = try await events.upcomingEvent(
                matching: owner.occurrence.eventID),
                  event.startDate == owner.occurrence.eventStartAt,
                  ExecuteStandingPreMeetingBrief.isEligible(event, at: now())
            else {
                await cancelConfirmedIfRevoked(owner)
                continue
            }
            _ = try? await executor.resume(owner, event: event)
        }
    }

    private func prepareUpcoming(
        activeRules: [StandingSkillRuleID: StandingSkillRule],
        executor: ExecuteStandingPreMeetingBrief
    ) async throws {
        guard !activeRules.isEmpty else {
            cancelScheduledWake()
            return
        }
        let upcoming = await events.upcomingStandingBriefEvents()
            .filter(\.hasValidIdentity)
            .sorted {
                $0.startDate == $1.startDate
                    ? $0.id < $1.id
                    : $0.startDate < $1.startDate
            }
        scheduleNextStandingWake(for: upcoming)
        var seenEventIDs = Set<String>()
        for rule in activeRules.values.sorted(by: {
            $0.createdAt == $1.createdAt
                ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
                : $0.createdAt < $1.createdAt
        }) {
            for event in upcoming where seenEventIDs.insert(event.id).inserted {
                try Task.checkCancellation()
                guard captureState.current == .inactive else {
                    needsReconciliation = true
                    return
                }
                guard ExecuteStandingPreMeetingBrief.isEligible(
                    event,
                    at: now())
                else { continue }
                let outcome = try? await executor.execute((rule, event))
                if outcome == .deferred(.dailyBudgetReached) { return }
            }
        }
    }

    private func makeExecutor() -> ExecuteStandingPreMeetingBrief {
        ExecuteStandingPreMeetingBrief(
            store: store,
            preparer: preparer,
            events: events,
            calendar: calendar,
            cancelsClaimOnCancellation: false,
            now: now)
    }

    private func cancelConfirmedIfRevoked(
        _ owner: PendingStandingSkillExecution
    ) async {
        guard owner.record.state == .confirmed else { return }
        _ = try? await store.cancelSkillExecution(
            proposalID: owner.record.proposalID,
            at: now())
    }

    private func cancelScheduledWake() {
        wakeTask?.cancel()
        wakeTask = nil
    }

    private func scheduleNextStandingWake(
        for events: [UpcomingEvent]
    ) {
        let timestamp = now()
        let next = Self.nextWakeDate(
            for: events,
            at: timestamp,
            calendar: calendar)
        wakeTask?.cancel()
        guard let next else {
            wakeTask = nil
            return
        }
        let delay = max(0, next.timeIntervalSince(timestamp))
        wakeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                await self?.kick()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    static func nextWakeDate(
        for events: [UpcomingEvent],
        at timestamp: Date,
        calendar: Calendar
    ) -> Date? {
        let nextLeadWindow = events.lazy
            .map {
                $0.startDate.addingTimeInterval(
                    -ExecuteStandingPreMeetingBrief.maximumPreparationLeadTime)
            }
            .filter { $0 > timestamp }
            .min()
        let dayStart = calendar.startOfDay(for: timestamp)
        let horizonRefresh = calendar.date(
            byAdding: .day,
            value: 1,
            to: dayStart)
        return [nextLeadWindow, horizonRefresh].compactMap { $0 }.min()
    }
}
