import XCTest

final class InterviewAssistUITests: PortavozUITestCase {
    /// Complete real-app EN/ES journey over the public/synthetic interview
    /// corpus: explicit mode, bounded objective, exact current question,
    /// pull-only answer, and exact cited source. No private meeting or model
    /// installation is required.
    @MainActor
    func testInterviewAssistGroundsTheCurrentQuestionInExactEvidence() {
        let app = XCUIApplication.portavoz(simulateInterviewAssist: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistenceFast(timeout: 15))
        let isSpanish = record.label == "Nueva grabación"
        record.click()

        let toggle = app.control(withIdentifier: "recording-interview-assist")
        XCTAssertTrue(toggle.waitForExistenceFast(timeout: 15))
        toggle.click()

        let panel = app.control(withIdentifier: "recording-interview-panel")
        XCTAssertTrue(panel.waitForExistenceFast(timeout: 10))
        let question = app.control(
            withIdentifier: "recording-interview-current-question")
        let expectedQuestion = isSpanish
            ? "¿Qué haría Camila primero durante el incidente?"
            : "What would Jordan do first during the database incident?"
        XCTAssertTrue(question.waitForLabelOrValue(expectedQuestion, timeout: 10))

        let scroll = app.control(withIdentifier: "recording-assist-scroll")
        XCTAssertTrue(scroll.waitForExistenceFast(timeout: 5))
        let objective = app.control(withIdentifier: "recording-objective-field")
        XCTAssertTrue(objective.waitForHittable(timeout: 5))
        objective.click()
        let objectiveText = isSpanish
            ? "Evaluar criterio de respuesta a incidentes"
            : "Evaluate incident-response judgment"
        app.typeText(objectiveText)
        objective.typeKey(.return, modifierFlags: [])
        let objectiveCount = app.control(
            withIdentifier: "recording-interview-objective-count")
        let expectedObjectiveCount = isSpanish
            ? "1 de 8 objetivos de entrevista"
            : "1 of 8 interview objectives"
        XCTAssertTrue(
            objectiveCount.waitForLabelOrValue(expectedObjectiveCount, timeout: 5),
            "objective admission must publish before proving its saved row")
        let savedObjective = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "recording-objective-text-",
                objectiveText))
            .firstMatch
        XCTAssertTrue(
            savedObjective.waitForExistenceFast(timeout: 5),
            "the product must materialize the exact admitted objective")
        XCTAssertTrue(
            savedObjective.revealVertically(
                in: scroll,
                maxScrolls: 0),
            "the product must keep the admitted objective fully visible "
                + "without a test-owned wheel gesture")

        let answerAction = app.control(withIdentifier: "recording-interview-answer")
        XCTAssertTrue(
            answerAction.revealVertically(in: scroll),
            "the answer action must be fully inside the assist viewport")
        answerAction.click()

        let answer = app.control(
            withIdentifier: "recording-interview-grounded-answer")
        XCTAssertTrue(waitForUITestCondition(timeout: 10) {
            self.accessibleText(of: answer).contains(isSpanish
                ? "cinco minutos"
                : "within five minutes")
        }, "the grounded answer must publish its exact bounded fact")
        let evidence = app.control(withIdentifier: "recording-interview-evidence-1")
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            self.accessibleText(of: evidence).contains(isSpanish
                ? "Avisaría a la responsable de base de datos"
                : "page the database owner within five minutes")
        }, "the answer must retain its exact same-meeting citation")
    }

    @MainActor
    private func accessibleText(of element: XCUIElement) -> String {
        [element.label, element.value as? String]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
