import ApplicationKit
import Foundation
import PortavozCore

extension AppServices {
    /// Two subject-scoped offers for the same Skill prove that the central
    /// content-free list gives Voice Control and VoiceOver distinct actions.
    /// Production never supplies this disposable-store-only argument.
    func seedDuplicateSkillProposalsIfRequested(
        for primaryMeeting: Meeting
    ) async {
        guard usesTemporaryMeetingStore,
              ProcessInfo.processInfo.arguments.contains(
                  "-seed-duplicate-skill-proposals")
        else { return }

        let secondaryMeeting = Meeting(
            title: "Older proposal fixture",
            startedAt: Date(timeIntervalSince1970: 1_699_900_000),
            endedAt: Date(timeIntervalSince1970: 1_699_900_600),
            language: "es")
        let observedAt = Date(timeIntervalSince1970: 1_700_000_300)

        do {
            try await store.save(secondaryMeeting)
            _ = try await store.saveSummary(SummaryDraft(
                meetingID: secondaryMeeting.id,
                recipeID: Recipe.general.id,
                language: "es",
                markdown: "Resumen de fixture sin contenido privado.",
                actionItems: []))
            _ = try await LoadMeetingSkillOffers(
                store: store,
                now: { observedAt }
            ).execute(LoadMeetingSkillOffersRequest(
                meetingID: primaryMeeting.id,
                hasSummary: true))
            _ = try await LoadMeetingSkillOffers(
                store: store,
                now: { observedAt.addingTimeInterval(-1) }
            ).execute(LoadMeetingSkillOffersRequest(
                meetingID: secondaryMeeting.id,
                hasSummary: true))
        } catch {
            assertionFailure(
                "Could not seed duplicate Skill proposals: \(error)")
        }
    }
}
