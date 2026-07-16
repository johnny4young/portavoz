import Foundation
import PortavozCore

extension AppServices {
    /// Adds a second recipe only for the D45 disposable UI fixture.
    func seedLatestRecipeSummaryIfRequested(for meetingID: MeetingID) async {
        guard ProcessInfo.processInfo.arguments.contains("-seed-latest-recipe") else { return }
        _ = try? await store.saveSummary(
            SummaryDraft(
                meetingID: meetingID, recipeID: Recipe.standup.id, language: "es",
                markdown: """
                    El resumen de standup sigue visible después de recargar.

                    ## Progreso
                    - El presupuesto de transcripción ya fue revisado.

                    ## Bloqueos
                    - Ninguno para el rollout del viernes.
                    """,
                actionItems: []))
    }

    func seedRunningRefineIfRequested(for meetingID: MeetingID) {
        refines.seedRunningForUITest(meetingID)
    }

    /// Marks the disposable seed as freshly recorded so XCUITest can exercise
    /// the one-shot post-meeting mirror without starting capture hardware.
    func seedJustRecordedIfRequested(for meetingID: MeetingID) {
        guard ProcessInfo.processInfo.arguments.contains("-seed-just-recorded") else { return }
        justRecorded = meetingID
    }
}
