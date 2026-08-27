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
        XCTAssertTrue(
            app.control(withIdentifier: "recording-interview-objective-count")
                .waitForExistenceFast(timeout: 5),
            "objective admission must publish before revealing its saved row")
        scroll.scroll(byDeltaX: 0, deltaY: -240)
        let savedObjective = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH 'recording-objective-text-'"))
            .firstMatch
        XCTAssertTrue(savedObjective.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(savedObjective.waitForLabelOrValue(objectiveText, timeout: 5))

        let answerAction = app.control(withIdentifier: "recording-interview-answer")
        XCTAssertTrue(
            answerAction.revealInsideInterviewViewport(scroll),
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

private extension XCUIElement {
    @MainActor
    func revealInsideInterviewViewport(
        _ viewportElement: XCUIElement,
        maxScrolls: Int = 6
    ) -> Bool {
        guard exists, viewportElement.exists else { return false }
        let viewport = viewportElement.frame.insetBy(dx: 0, dy: 4)
        let isVisible = {
            let controlFrame = self.frame
            return self.isHittable
                && !controlFrame.isEmpty
                && viewport.contains(controlFrame)
        }
        if isVisible(), waitForStableFrame(timeout: 1, stableFor: 0.1) {
            return isVisible()
        }
        for _ in 0..<maxScrolls {
            let controlFrame = frame
            let distance: CGFloat
            let direction: CGFloat
            if controlFrame.maxY > viewport.maxY {
                distance = controlFrame.maxY - viewport.maxY + 16
                direction = -1
            } else if controlFrame.minY < viewport.minY {
                distance = viewport.minY - controlFrame.minY + 16
                direction = 1
            } else {
                distance = 120
                direction = -1
            }
            viewportElement.scroll(
                byDeltaX: 0,
                deltaY: direction * min(max(distance, 120), 360))
            if isVisible(), waitForStableFrame(timeout: 1, stableFor: 0.1) {
                return isVisible()
            }
        }
        return false
    }
}
