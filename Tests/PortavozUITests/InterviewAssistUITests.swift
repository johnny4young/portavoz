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
        let savedObjective = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "recording-objective-text-",
                objectiveText))
            .firstMatch
        XCTAssertTrue(
            savedObjective.revealInsideInterviewViewport(
                scroll,
                missingTargetDeltaY: -48),
            "the admitted objective must be visible with its exact text")

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
        maxScrolls: Int = 6,
        missingTargetDeltaY: CGFloat? = nil,
        maximumStep: CGFloat = 48
    ) -> Bool {
        guard viewportElement.exists else { return false }
        guard maximumStep > 0 else { return false }
        if waitForStableContainedFrame(
            in: viewportElement,
            timeout: 0.25
        ) {
            return true
        }
        for _ in 0..<maxScrolls {
            let viewport = viewportElement.frame.insetBy(dx: 0, dy: 4)
            let distance: CGFloat
            let direction: CGFloat
            if !exists {
                guard let missingTargetDeltaY else { return false }
                distance = abs(missingTargetDeltaY)
                direction = missingTargetDeltaY < 0 ? -1 : 1
            } else {
                let controlFrame = frame
                if controlFrame.isEmpty {
                    guard let missingTargetDeltaY else { return false }
                    distance = abs(missingTargetDeltaY)
                    direction = missingTargetDeltaY < 0 ? -1 : 1
                } else if controlFrame.maxY > viewport.maxY {
                    distance = controlFrame.maxY - viewport.maxY + 16
                    direction = -1
                } else if controlFrame.minY < viewport.minY {
                    distance = viewport.minY - controlFrame.minY + 16
                    direction = 1
                } else {
                    return waitForStableContainedFrame(
                        in: viewportElement,
                        timeout: 1)
                }
            }
            viewportElement.scroll(
                byDeltaX: 0,
                deltaY: direction * min(max(distance, 16), maximumStep))
            if waitForStableContainedFrame(in: viewportElement, timeout: 1) {
                return true
            }
        }
        return false
    }

    @MainActor
    private func waitForStableContainedFrame(
        in viewportElement: XCUIElement,
        timeout: TimeInterval,
        stableFor stableInterval: TimeInterval = 0.1
    ) -> Bool {
        var candidateFrame: CGRect?
        var stableSince: Date?
        return waitForUITestCondition(timeout: timeout) {
            guard self.exists, viewportElement.exists else {
                candidateFrame = nil
                stableSince = nil
                return false
            }
            let controlFrame = self.frame
            let viewport = viewportElement.frame.insetBy(dx: 0, dy: 4)
            guard self.isHittable,
                  !controlFrame.isEmpty,
                  viewport.contains(controlFrame)
            else {
                candidateFrame = nil
                stableSince = nil
                return false
            }
            if candidateFrame != controlFrame {
                candidateFrame = controlFrame
                stableSince = Date()
                return stableInterval <= 0
            }
            guard let stableSince else { return false }
            return Date().timeIntervalSince(stableSince) >= stableInterval
        }
    }
}
