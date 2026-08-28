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
        XCTAssertTrue(question.waitForExistenceFast(timeout: 10))
        let expectedQuestion = isSpanish
            ? "¿Qué haría Camila primero durante el incidente?"
            : "What would Jordan do first during the database incident?"
        XCTAssertTrue(question.waitForLabelOrValue(expectedQuestion, timeout: 5))

        let scroll = app.control(withIdentifier: "recording-assist-scroll")
        XCTAssertTrue(scroll.waitForExistenceFast(timeout: 5))
        let objective = app.control(withIdentifier: "recording-objective-field")
        XCTAssertTrue(objective.waitForExistenceFast(timeout: 5))
        for _ in 0..<4 where !objective.isHittable {
            scroll.swipeUp()
        }
        XCTAssertTrue(objective.waitForHittable(timeout: 5))
        objective.click()
        let objectiveText = isSpanish
            ? "Evaluar criterio de respuesta a incidentes"
            : "Evaluate incident-response judgment"
        app.typeText(objectiveText)
        let add = app.control(withIdentifier: "recording-objective-add")
        XCTAssertTrue(add.waitForHittable(timeout: 5))
        add.click()
        let objectiveCount = app.control(
            withIdentifier: "recording-interview-objective-count")
        XCTAssertTrue(
            objectiveCount.waitForExistenceFast(timeout: 5),
            "objective admission must publish before revealing its saved row")
        XCTAssertTrue(
            objectiveCount.revealVertically(in: scroll),
            "the admitted objective count must enter the assist viewport")
        let savedObjective = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "recording-objective-text-",
                objectiveText))
            .firstMatch
        XCTAssertTrue(
            savedObjective.waitForExistenceFast(timeout: 5),
            "the admitted objective must publish its exact accessibility row")
        XCTAssertTrue(
            savedObjective.revealVertically(in: scroll),
            "the admitted objective must be visible with its exact text")

        let answerAction = app.control(withIdentifier: "recording-interview-answer")
        XCTAssertTrue(
            answerAction.revealVertically(in: scroll),
            "the answer action must be fully inside the assist viewport")
        answerAction.click()

        let answer = app.control(
            withIdentifier: "recording-interview-grounded-answer")
        XCTAssertTrue(answer.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            self.accessibleText(of: answer).contains(isSpanish
                ? "cinco minutos"
                : "within five minutes")
        })
        let evidence = app.control(withIdentifier: "recording-interview-evidence-1")
        XCTAssertTrue(evidence.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            self.accessibleText(of: evidence).contains(isSpanish
                ? "Avisaría a la responsable de base de datos"
                : "page the database owner within five minutes")
        })
    }

    @MainActor
    private func accessibleText(of element: XCUIElement) -> String {
        [element.label, element.value as? String]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
