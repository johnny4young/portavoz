import ApplicationKit
import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit

extension AppServices {
    /// Creates the one presentation owner mounted by the resident menu-bar
    /// scene. AppServices remains composition; Store and EventKit stay private.
    func makeMenuBarModel() -> MenuBarModel {
        MenuBarModel(client: self)
    }
}

extension AppServices: MenuBarModelClient {
    func observeMenuBar() -> AsyncStream<MenuBarUpdate> {
        makeApplicationMenuBarStream(
            meetings: store.observeMenuBarMeetings(limit: 3),
            openItems: store.observeLibraryOpenItems(limit: 200))
    }

    func nextMenuBarEvent() async -> UpcomingEvent? {
        await upcomingEventSource.nextEvent()
    }

    func menuBarBriefOffer(
        for event: UpcomingEvent
    ) async -> PreMeetingBriefOffer? {
        try? await LoadPreMeetingBriefOffer(store: store).execute(event)
    }

    func prepareMenuBarBrief(
        for event: UpcomingEvent
    ) async -> MeetingBrief? {
        try? await meetingBriefUseCase.execute(event)
    }

    func dismissMenuBarBriefOffer(_ offer: PreMeetingBriefOffer) async throws {
        try await DismissPreMeetingBriefOffer(store: store).execute(offer)
    }

    func performMenuBarBriefSkill(
        proposalID: UUID,
        offer: PreMeetingBriefOffer,
        approvedBrief: MeetingBrief
    ) async throws -> String? {
        guard approvedBrief.event == offer.event,
              let currentEvent = try await upcomingEventSource.upcomingEvent(
                matching: offer.event.id),
              currentEvent == offer.event
        else { return staleMenuBarBriefFailure }
        let key = offer.offerKey
        let existing = try await store.skillExecution(idempotencyKey: key)
        guard let durableProposalID = PreMeetingBriefProposalFactory.durableProposalID(
            requested: proposalID,
            existing: existing,
            idempotencyKey: key),
              let built = PreMeetingBriefProposalFactory.proposal(
                proposalID: durableProposalID,
                eventID: offer.event.id,
                at: Date())
        else { return staleMenuBarBriefFailure }
        let outcome = try await ExecuteSkill(
            claims: store,
            policy: store,
            effects: [
                PreMeetingBriefSkill.id: PreMeetingBriefEffect(
                    material: approvedBrief,
                    delivery: meetingBriefSkillDelivery)
            ]
        ).execute(ExecuteSkillRequest(
            proposal: built.proposal,
            isConfirmedByUser: true,
            egressIsPermitted: false,
            offerKey: offer.offerKey,
            idempotencyKey: key))
        let failure = menuBarBriefFailure(for: outcome)
        if failure == nil {
            _ = await meetingBriefSkillDelivery.take(eventID: offer.event.id)
        }
        return failure
    }

    private func menuBarBriefFailure(
        for outcome: SkillExecutionOutcome
    ) -> String? {
        switch outcome {
        case .performed, .alreadySettled(.succeeded):
            return nil
        case .refused(.allSkillsPaused):
            return L10n.text("Actions are paused in Settings.")
        case .refused(.skillDisabled):
            return L10n.text("This action is disabled in Settings.")
        case .failed:
            return L10n.text("The brief could not be delivered. Nothing left Portavoz.")
        case .alreadySettled, .refused, .rejected:
            return staleMenuBarBriefFailure
        }
    }

    private var staleMenuBarBriefFailure: String {
        L10n.text("This brief changed or is no longer on your calendar. Review it again.")
    }
}

/// EventKit stays behind one actor so the resident brief proposal never reads
/// calendars on the main actor. The temporary-store fixture is admitted only
/// with its exact seed flag and never consults the host calendar or TCC state.
actor AppUpcomingEventSource: StandingPreMeetingBriefEventSource {
    private let usesTemporaryStore: Bool
    private let seededEvent: UpcomingEvent?

    init(arguments: [String], usesTemporaryStore: Bool) {
        self.usesTemporaryStore = usesTemporaryStore
        seededEvent = usesTemporaryStore && arguments.contains("-seed-brief")
            ? UpcomingEvent(
                id: "ui-test-upcoming-rollout",
                title: "Presupuesto rollout",
                startDate: Date().addingTimeInterval(15 * 60),
                attendees: ["Ana"])
            : nil
    }

    func nextEvent() -> UpcomingEvent? {
        if usesTemporaryStore { return seededEvent }
        guard !CalendarAttendeeSource.accessUndetermined else { return nil }
        return CalendarAttendeeSource().nextEvent()
    }

    func upcomingEvent(matching identifier: String) throws -> UpcomingEvent? {
        if usesTemporaryStore {
            return seededEvent?.id == identifier ? seededEvent : nil
        }
        return CalendarAttendeeSource().event(matching: identifier)
    }

    func upcomingStandingBriefEvents() -> [UpcomingEvent] {
        if usesTemporaryStore { return seededEvent.map { [$0] } ?? [] }
        guard !CalendarAttendeeSource.accessUndetermined else { return [] }
        return CalendarAttendeeSource().upcomingEvents()
    }

    func standingBriefEventChanges() -> AsyncStream<Void> {
        guard !usesTemporaryStore else {
            return AsyncStream { $0.finish() }
        }
        return CalendarAttendeeSource.eventChanges()
    }
}

/// The Skill's local-draft effect crosses this boundary before its durable
/// succeeded settlement. Presentation consumes the value immediately; the
/// dictionary prevents one event from overwriting another concurrent draft.
actor AppMeetingBriefSkillDelivery: MeetingBriefDelivering {
    private var delivered: [String: MeetingBrief] = [:]

    func deliver(_ brief: MeetingBrief) {
        delivered[brief.event.id] = brief
    }

    func take(eventID: String) -> MeetingBrief? {
        delivered.removeValue(forKey: eventID)
    }
}

private func makeApplicationMenuBarStream(
    meetings: AsyncThrowingStream<[Meeting], Error>,
    openItems: AsyncThrowingStream<[MeetingStore.OpenActionItem], Error>
) -> AsyncStream<MenuBarUpdate> {
    AsyncStream { continuation in
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        for try await value in meetings {
                            continuation.yield(.meetings(value.map {
                                MenuBarMeeting(
                                    id: $0.id,
                                    title: $0.title,
                                    startedAt: $0.startedAt)
                            }))
                        }
                    } catch is CancellationError {
                        // Parent cancellation ends the complete merged stream.
                    } catch {
                        continuation.yield(.failed(.meetings))
                    }
                }
                group.addTask {
                    do {
                        for try await value in openItems {
                            continuation.yield(.pendingCounts(
                                Dictionary(grouping: value, by: \.meetingID)
                                    .mapValues(\.count)))
                        }
                    } catch is CancellationError {
                        // Parent cancellation ends the complete merged stream.
                    } catch {
                        continuation.yield(.failed(.pendingCounts))
                    }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
