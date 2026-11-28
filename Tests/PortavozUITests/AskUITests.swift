import XCTest

/// Ask's answer page: the question as its title, the answer with numbered
/// markers, who said each quote, and the follow-ups above the composer.
final class AskUITests: PortavozUITestCase {
    @MainActor
    func testAnswerNamesWhoSaidItOpensItsCommitmentAndAsksAFollowUp() throws {
        let app = try XCUIApplication.portavoz(
            seedDemo: true, seedCommitmentRadar: true, simulateNoAppleIntelligence: true)
        app.launchArguments.append("-seed-light-appearance")
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        ask("viernes", in: app)
        let speaker = element("ask-evidence-", endingWith: "-1-speaker", in: app)
        XCTAssertTrue(speaker.waitForExistenceFast(timeout: 10), "the quote must lead with who said it")
        XCTAssertTrue(renderedText(of: speaker).contains("Ana"), renderedText(of: speaker))
        let meeting = element("ask-evidence-", endingWith: "-1-meeting", in: app)
        XCTAssertTrue(renderedText(of: meeting).contains("Test meeting"), renderedText(of: meeting))
        XCTAssertTrue(renderedText(of: meeting).contains("00:03"), renderedText(of: meeting))
        XCTAssertTrue(element("ask-question-", endingWith: "-receipt", in: app).exists)
        let source = element("ask-generated-from-", in: app)
        XCTAssertTrue(source.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(
            waitForUITestCondition(timeout: 5) { renderedText(of: source).contains("1 voice in 1 meeting") },
            renderedText(of: source))
        let followUp = app.buttons["ask-follow-up-0"]
        XCTAssertTrue(followUp.waitForExistenceFast(timeout: 10), "a generated answer offers its follow-ups")
        attachScreenshot(of: app, named: "pr-ask-who-said-it")
        let copy = element("ask-copy-markdown-", in: app)
        XCTAssertTrue(copy.exists, "an answer offers Copy as Markdown")

        let commitments = element("ask-open-commitments-", in: app)
        XCTAssertTrue(commitments.waitForExistenceFast(timeout: 5))
        XCTAssertEqual(renderedText(of: commitments), "1 open commitment")
        commitments.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["commitment-radar"].waitForExistenceFast(timeout: 10),
            "the open commitment behind a quote opens in Radar")

        app.buttons["library-ask-button"].click()
        XCTAssertTrue(followUp.waitForExistenceFast(timeout: 10), "the conversation survives a trip to Radar")
        let suggestion = renderedText(of: followUp)
        followUp.click()
        let questions = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'ask-question-' AND NOT identifier ENDSWITH '-receipt' "
                + "AND identifier != 'ask-question-field'"))
        XCTAssertTrue(waitForUITestCondition(timeout: 10) { questions.count == 2 })
        XCTAssertEqual(renderedText(of: questions.element(boundBy: 1)), suggestion)

        let play = element("ask-evidence-", endingWith: "-1-play", in: app)
        XCTAssertTrue(play.waitForStableFrame(timeout: 5))
        play.click()
        let currentTime = app.staticTexts["player-current-time"]
        XCTAssertTrue(currentTime.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(currentTime.waitForValue("0:03", timeout: 10))
    }

    @MainActor
    func testNarrowDarkAnswerStacksTheMomentUnderTheQuote() throws {
        let app = try XCUIApplication.portavoz(seedDemo: true, simulateNoAppleIntelligence: true)
        app.launchArguments += ["-seed-narrow-window"] + XCUIApplication.appearanceArguments(dark: true)
        app.launchPortavoz()
        defer { finishUITestApplication(app) }

        ask("viernes", in: app)
        let speaker = element("ask-evidence-", endingWith: "-1-speaker", in: app)
        let meeting = element("ask-evidence-", endingWith: "-1-meeting", in: app)
        let play = element("ask-evidence-", endingWith: "-1-play", in: app)
        XCTAssertTrue(speaker.waitForStableFrame(timeout: 10))
        XCTAssertTrue(play.waitForStableFrame(timeout: 5))
        XCTAssertEqual(meeting.frame.minX, speaker.frame.minX, accuracy: 2, "a narrow row stacks the quote under who said it")
        XCTAssertGreaterThan(play.frame.minY, meeting.frame.maxY, "and the moment under the quote")
        let field = app.textFields["ask-question-field"]
        let submit = app.buttons["ask-submit"]
        XCTAssertLessThan(field.frame.maxX, app.buttons["ask-source-library"].frame.minX)
        XCTAssertLessThanOrEqual(submit.frame.maxX, app.windows.firstMatch.frame.maxX)
        attachScreenshot(of: app, named: "pr-ask-who-said-it-narrow-dark")
    }

    @MainActor
    private func ask(_ question: String, in app: XCUIApplication) {
        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        app.buttons["library-ask-button"].click()
        let field = app.textFields["ask-question-field"]
        XCTAssertTrue(field.waitForExistenceFast(timeout: 10))
        field.click()
        typeText(question, in: app)
        XCTAssertTrue(field.waitForValue(question, timeout: 5))
        app.buttons["ask-submit"].click()
    }

    @MainActor
    private func element(_ prefix: String, endingWith suffix: String? = nil, in app: XCUIApplication) -> XCUIElement {
        let format = suffix == nil
            ? "identifier BEGINSWITH %@"
            : "identifier BEGINSWITH %@ AND identifier ENDSWITH %@"
        let arguments: [Any] = [prefix] + (suffix.map { [$0] } ?? [])
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: format, argumentArray: arguments)).firstMatch
    }
}
