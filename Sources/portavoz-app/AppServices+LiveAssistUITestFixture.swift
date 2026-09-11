import Foundation
import PortavozCore

/// Created only by disposable app composition. The controller receives normal
/// card outcomes and objective actions rather than replacing its private state.
@MainActor
final class LiveAssistUITestFixture {
    let summaryInterval: Duration
    let simulateStopIntent: Bool
    private let companion: Bool
    private let translation: Bool
    private let showcase: Bool
    private let arrivals: Bool
    private var seededMeetingID: MeetingID?
    private var advanced = false

    init?(arguments: [String], usesTemporaryStore: Bool) {
        guard usesTemporaryStore else { return nil }
        companion = arguments.contains("-seed-live-companion-ui")
        translation = arguments.contains("-seed-live-translation-ui")
        showcase = arguments.contains("-seed-showcase")
        arrivals = arguments.contains("-seed-live-assist-arrivals-ui")
        simulateStopIntent = arguments.contains("-simulate-stop-app-intent")
        summaryInterval = arguments.contains("-seed-live-summary-ui")
            ? .milliseconds(50) : .seconds(40)
    }

    func receiveCaption(in controller: RecordingController) {
        guard let row = controller.captions.last else { return }
        if translation {
            if controller.translationTarget == nil { controller.translationTarget = "en" }
            controller.translations[row.id] = showcase
                ? PublicShowcaseFixture.translation(for: row.text)
                : "Clearly separated test translation."
            controller.translatedSourceTexts[row.id] = row.text
        }
        guard companion else { return }
        if seededMeetingID != row.meetingID {
            seededMeetingID = row.meetingID
            advanced = false
            for index in 1...6 {
                admit(CompanionCard(
                    question: "Seeded live question \(index)?",
                    answer: String(repeating: "Seeded live answer \(index). ", count: 12),
                    kind: .context, source: "on-device",
                    askedAt: row.startTime + Double(index - 1)), in: controller)
                if arrivals {
                    controller.addObjective(
                        "Initial objective \(index): review the release evidence and explain the remaining risks before approval.")
                }
            }
            admit(CompanionCard(
                question: "Ana, can you take the budget?", answer: "",
                kind: .context, source: "on-device", directed: true,
                askedAt: row.startTime + 7), in: controller)
        }
        // The existing transcript fixture waits at row 18 until XCUITest
        // releases it; row 19 submits one batch, published after its commit.
        guard arrivals, !advanced, row.startTime >= 38 else { return }
        advanced = true
        controller.addObjectives([
            "Confirm release readiness with the team and record every remaining risk before approval.",
            "Revisar la evidencia con el equipo y registrar los riesgos pendientes antes de aprobar la versión."
        ])
        if let previous = controller.companionCards.first(where: { $0.question == "Seeded live question 6?" }) {
            admit(CompanionCard(
                question: "Seeded live question 6? Please.", answer: previous.answer,
                kind: previous.kind, source: previous.source,
                askedAt: previous.askedAt), in: controller)
        }
    }

    private func admit(_ card: CompanionCard, in controller: RecordingController) {
        let run = GenerationRun(
            meetingID: controller.meetingID, kind: .companion,
            providerID: "ui-test", modelID: "synthetic-fixture",
            inputFingerprint: String(repeating: "0", count: 64), configJSON: "{}",
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1), outcome: .succeeded)
        controller.recordCompanionOutcome(
            .artifact(CompanionGenerationArtifact(card: card, generationRun: run)),
            sourceMeetingID: controller.meetingID)
    }
}

extension AppServices {
    func simulateStopIntentIfRequested() {
        guard liveAssistUITestFixture?.simulateStopIntent == true,
              recording.phase == .recording else { return }
        _ = PortavozAppIntentBridge.requestStopRecording()
    }
}
