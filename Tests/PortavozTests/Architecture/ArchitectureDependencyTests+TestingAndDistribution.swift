import ApplicationKit
import Foundation
import XCTest

extension ArchitectureDependencyTests {
    func testMainActorXCTestMethodsStayAsyncForSequoiaCompatibility() throws {
        XCTAssertEqual(
            try Self.synchronousMainActorXCTestMethods(),
            [],
            "@MainActor XCTest methods must remain async while "
                + "Sequoia carries swiftlang/swift#87316")
    }

    func testMainActorXCTestRatchetFindsMethodAndClassIsolation() {
        let source = [
            "final class MethodTests: XCTestCase {",
            "    @MainActor",
            "    func testSyncMethod() throws {}",
            "    @MainActor",
            "    @available(macOS 14, *)",
            "    func testMultilineMethod()",
            "        throws {}",
            "    @MainActor",
            "    func testAsyncMethod() async throws {}",
            "    @MainActor func testInlineMethod() {}",
            "    func testOrdinaryMethod() {}",
            "}",
            "@MainActor",
            "final class ClassTests: XCTestCase {",
            "    func testSyncClassMethod() {}",
            "    @MainActor",
            "    func testBothAnnotations() {}",
            "    func testAsyncClassMethod() async {}",
            "}",
        ].joined(separator: "\n")

        XCTAssertEqual(Self.synchronousMainActorXCTestMethods(
            in: source, file: "Fixture.swift"), [
                "Fixture.swift:testSyncMethod",
                "Fixture.swift:testMultilineMethod",
                "Fixture.swift:testInlineMethod",
                "Fixture.swift:testSyncClassMethod",
                "Fixture.swift:testBothAnnotations",
            ])
    }

    func testMainActorXCTestRatchetIgnoresHelpersAndAsyncDeclarations() {
        let source = [
            "final class MixedTests: XCTestCase {",
            "    @MainActor",
            "    func helper() {}",
            "    func testUnisolated() {}",
            "    @MainActor",
            "    func testAsync()",
            "        async throws {}",
            "}",
            "// @MainActor",
            "final class OrdinaryTests: XCTestCase {",
            "    func testOrdinary() {}",
            "}",
        ].joined(separator: "\n")

        XCTAssertEqual(Self.synchronousMainActorXCTestMethods(
            in: source, file: "Fixture.swift"), [])
    }

    func testScheduledPresentationTestsControlSuspensionWithoutWallClockSleeps() throws {
        let relay = try Self.contents(
            of: "Sources/portavoz-app/RecordingLevelRelay.swift")
        let focus = try Self.contents(
            of: "Sources/portavoz-app/SettingsSkillReceiptFocusState.swift")
        let relayTests = try Self.contents(
            of: "Tests/PortavozTests/RecordingLevelRelayTests.swift")
        let focusTests = try Self.contents(
            of: "Tests/PortavozTests/SettingsSkillReceiptFocusStateTests.swift")

        XCTAssertTrue(relay.contains("typealias Sleep = @Sendable"))
        XCTAssertTrue(focus.contains("typealias Sleep = @Sendable"))
        XCTAssertTrue(relayTests.contains("ControlledTestSleep"))
        XCTAssertTrue(focusTests.contains("ControlledTestSleep"))
        XCTAssertFalse(relayTests.contains("Task.sleep"))
        XCTAssertFalse(focusTests.contains("Task.sleep"))
    }

    func testArchitectureDocumentUsesOnlyDurableTechnicalVocabulary() throws {
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let forbidden = try NSRegularExpression(
            pattern: #"(?i)\b(band|slice|ticket|phase)\b|\b[DM][0-9]+\b|target architecture|next program|\bplanned\b"#)
        let range = NSRange(architecture.startIndex..., in: architecture)
        XCTAssertNil(
            forbidden.firstMatch(in: architecture, range: range),
            "ARCHITECTURE.md must describe only durable as-built technical facts")
    }

    func testArchitectureDecisionIdentifiersAreUnique() throws {
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let identifiers = decisions.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("## D") else { return nil }
            let digits = line.dropFirst(4).prefix(while: \.isNumber)
            return digits.isEmpty ? nil : "D\(digits)"
        }
        let duplicates = Dictionary(grouping: identifiers, by: { $0 })
            .filter { $0.value.count > 1 }
            .map(\.key)
            .sorted()

        XCTAssertFalse(identifiers.isEmpty)
        XCTAssertTrue(
            duplicates.isEmpty,
            "Architecture decision identifiers must be unique: \(duplicates)")
    }

    func testXCUITestInteractionPreparationReassertsFrontmostOwnership() throws {
        let support = try Self.contents(
            of: "Tests/PortavozUITests/UITestSupport.swift")
        let launchAction = try XCTUnwrap(support.range(of: "        launch()"))
        let launchForeground = try XCTUnwrap(support.range(
            of: "wait(for: .runningForeground, timeout: 15)"))
        let launchWindow = try XCTUnwrap(support.range(
            of: "let mainWindow = windows[\"main-AppWindow-1\"]"))
        let launchReadiness = support[launchAction.upperBound..<launchWindow.lowerBound]
        let launchActivation = try XCTUnwrap(launchReadiness.range(of: "        activate()"))
        XCTAssertLessThan(
            launchActivation.lowerBound, launchForeground.lowerBound,
            "request frontmost ownership before observing foreground; process state alone is insufficient")
        XCTAssertEqual(launchReadiness.components(separatedBy: "        activate()").count - 1, 1)
        XCTAssertFalse(launchReadiness.contains("if state == .runningForeground"))

        let prepare = try XCTUnwrap(support.range(
            of: "func prepareForInteraction(timeout: TimeInterval = 10)"))
        let activation = try XCTUnwrap(support.range(
            of: "activate()", range: prepare.upperBound..<support.endIndex))
        let foregroundWait = try XCTUnwrap(support.range(
            of: "wait(for: .runningForeground, timeout: timeout)",
            range: activation.upperBound..<support.endIndex))
        XCTAssertLessThan(activation.lowerBound, foregroundWait.lowerBound)
        XCTAssertFalse(support[prepare.upperBound..<foregroundWait.lowerBound].contains(
            "if state == .runningForeground"))
        XCTAssertTrue(support.contains("waitForPortavozProcessExit()"))
        XCTAssertTrue(support.contains("wait(for: .notRunning, timeout: 10)"))
        XCTAssertTrue(try Self.contents(of: "docs/DECISIONS.md").contains("## D413"))
    }

    func testHostedUIFunctionalGateSeparatesRunnerDriftFromControlledBudgets() throws {
        let workflow = try Self.contents(of: ".github/workflows/ui-tests.yml")
        let makefile = try Self.contents(of: "Makefile")
        let runner = try Self.contents(of: "scripts/run-ui-tests.sh")
        let runtime = try Self.contents(of: "scripts/ui_test_runtime.py")
        let gate = try Self.contents(of: "scripts/ui_test_ci_gate.py")
        let execution = try Self.contents(of: "scripts/ui_test_execution.py")
        let verifiedBase = try Self.contents(
            of: "scripts/ui_test_verified_base.py")
        let anchor = try Self.contents(
            of: "scripts/ui_test_verification_anchor.py")
        let ci = try Self.contents(of: ".github/workflows/ci.yml")
        let swiftLint = try Self.contents(of: "scripts/run-ci-swiftlint.sh")
        let xcodegen = try Self.contents(of: "scripts/install-ci-xcodegen.sh")
        let candidate = try Self.contents(of: "scripts/candidate_automation.py")
        let scope = try Self.contents(of: "scripts/ui_test_scope.py")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        // D496: one build job publishes the exact products; one matrix lane
        // per locale restores them; one Linux classifier reads every lane.
        XCTAssertEqual(
            workflow.components(separatedBy: "run: make test-ui-build").count - 1,
            1)
        XCTAssertEqual(
            workflow.components(separatedBy: "run: make test-ui-run").count - 1,
            1)
        XCTAssertEqual(
            workflow.components(separatedBy: "continue-on-error: true").count - 1,
            1,
            "each first-attempt locale lane must finish before the final classifier")
        XCTAssertEqual(
            workflow.components(
                separatedBy: "UI_TEST_ENFORCE_RUNTIME_BUDGET: \"false\"").count - 1,
            1)
        XCTAssertTrue(workflow.contains("locale: ${{ fromJSON(needs.scope.outputs.matrix) }}"))
        XCTAssertTrue(workflow.contains("UI_TEST_PRODUCTS_PATH:"))
        let artifact = try XCTUnwrap(workflow.range(
            of: "Preserve ${{ matrix.locale }} UI evidence"))
        let classifier = try XCTUnwrap(workflow.range(
            of: "Classify functional evidence and hosted runtime drift"))
        XCTAssertLessThan(artifact.lowerBound, classifier.lowerBound)
        XCTAssertTrue(workflow.contains("--english-outcome \"$(outcome en)\""))
        XCTAssertTrue(workflow.contains("--spanish-outcome \"$(outcome es)\""))
        XCTAssertFalse(workflow.contains("run: make test-ui-scoped"))
        XCTAssertTrue(workflow.contains("scripts/ui_test_verified_base.py"))
        XCTAssertTrue(workflow.contains("ui-verification-${{"))
        XCTAssertTrue(workflow.contains("github.run_attempt == 1"))
        XCTAssertFalse(workflow.contains("github.event.before"))
        XCTAssertTrue(workflow.contains("runs-on: macos-26"))
        XCTAssertTrue(workflow.contains("Xcode_26.6.app/Contents/Developer"))

        XCTAssertTrue(makefile.contains("test-ui-scoped: test-ui-build"))
        XCTAssertTrue(makefile.contains("test-ui-build: project"))
        XCTAssertTrue(makefile.contains("test-ui-run:"))
        let runTarget = try XCTUnwrap(makefile.range(of: "test-ui-run:"))
        let changedTarget = try XCTUnwrap(makefile.range(
            of: "test-ui-changed:", range: runTarget.upperBound..<makefile.endIndex))
        let runBody = makefile[runTarget.lowerBound..<changedTarget.lowerBound]
        XCTAssertTrue(runBody.contains("test-ui-preflight"))
        XCTAssertTrue(runBody.contains("UI_TEST_PHASE=test-only"))

        XCTAssertEqual(
            runner.components(separatedBy: "xcodebuild build-for-testing").count - 1,
            1)
        XCTAssertTrue(runner.contains("UI_TEST_PHASE:-build-and-test"))
        XCTAssertTrue(runner.contains("build-duration-seconds.txt"))
        XCTAssertTrue(runner.contains("UI_TEST_ENFORCE_RUNTIME_BUDGET:-true"))
        XCTAssertTrue(runner.contains("scripts/ui_test_execution.py"))
        XCTAssertTrue(runner.contains("execution_receipt"))
        XCTAssertTrue(gate.contains("hosted-runtime-drift"))
        XCTAssertTrue(gate.contains("product-or-test-regression"))
        XCTAssertTrue(gate.contains("infrastructure-or-harness"))
        XCTAssertTrue(gate.contains("evidence-contract violations"))
        XCTAssertTrue(gate.contains("wall-clock budgets remain advisory"))
        XCTAssertTrue(gate.contains("known-host-infrastructure"))
        XCTAssertTrue(gate.contains("automation-mode-timeout"))
        XCTAssertTrue(execution.contains(
            "Timed out while enabling automation mode"))
        XCTAssertTrue(execution.contains(
            "if runtime_cases is not None and runtime_cases > 0"))
        XCTAssertTrue(verifiedBase.contains("raw_run.get(\"run_attempt\") != 1"))
        XCTAssertTrue(verifiedBase.contains(
            "history.is_ancestor(candidate, head)"))
        XCTAssertTrue(anchor.contains("ui-functional-verification"))
        XCTAssertTrue(anchor.contains("selectorSHA256"))
        XCTAssertTrue(ci.contains("runs-on: macos-26"))
        XCTAssertTrue(ci.contains(
            "scripts/run-swift-tests.sh -Xswiftc -warnings-as-errors"))
        XCTAssertFalse(ci.contains("run: swift build"))
        XCTAssertFalse(ci.contains("Select newest Xcode"))
        XCTAssertTrue(swiftLint.contains("version=\"0.65.0\""))
        XCTAssertTrue(xcodegen.contains("version=\"2.46.0\""))
        XCTAssertTrue(runtime.contains("RECEIPT_SCHEMA_VERSION = 3"))
        XCTAssertTrue(runtime.contains(
            "HARNESS_NOISE_THRESHOLD_SECONDS = 1.0"))
        XCTAssertTrue(runtime.contains(
            "activity[\"title\"].startswith(\"Start Test at \""))
        XCTAssertTrue(runtime.contains(
            "activity.get(\"title\") == \"Set Up\""))
        XCTAssertTrue(runtime.contains(
            "activity.get(\"title\") == \"Tear Down\""))
        XCTAssertTrue(runtime.contains("case.result == \"Passed\""))
        XCTAssertTrue(runtime.contains("attributed <= reported"))
        XCTAssertTrue(runtime.contains(
            "excludedPreSetupSeconds"))
        XCTAssertTrue(runtime.contains(
            "excludedPostTeardownSeconds"))
        XCTAssertTrue(runtime.contains(
            "reason\": \"outside-test-activity-boundaries"))
        XCTAssertTrue(gate.contains("RECEIPT_SCHEMA_VERSION = 3"))
        XCTAssertTrue(gate.contains("runtime adjustment values differ"))
        XCTAssertTrue(candidate.contains("UI_RECEIPT_SCHEMA_VERSION = 3"))
        XCTAssertTrue(candidate.contains(
            "UI_HARNESS_NOISE_THRESHOLD_SECONDS = 1.0"))
        XCTAssertTrue(scope.contains("FULL_BILINGUAL_HARNESS_FILES"))
        XCTAssertTrue(scope.contains("scripts/ui_test_runtime.py"))
        XCTAssertTrue(scope.contains("scripts/ui_test_ci_gate.py"))
        XCTAssertTrue(scope.contains("scripts/candidate_automation.py"))
        XCTAssertTrue(scope.contains(".github/workflows/ui-tests.yml"))
        XCTAssertTrue(scope.contains("docs/evidence/ui-test-runtime-budget.json"))
        XCTAssertTrue(decisions.contains("## D425"))
        XCTAssertTrue(decisions.contains("## D428"))
        XCTAssertTrue(decisions.contains("## D429"))
        XCTAssertTrue(decisions.contains("## D446"))
    }

    func testXCUITestRuntimeOptimizationRetainsRiskOwnersWithoutDuplicateWork() throws {
        let support = try Self.contents(
            of: "Tests/PortavozUITests/UITestSupport.swift")
        let skills = try Self.contents(
            of: "Tests/PortavozUITests/SkillsSettingsUITests.swift")
        let meeting = try Self.contents(
            of: "Tests/PortavozUITests/MeetingDetailUITests.swift")
        let library = try Self.contents(
            of: "Tests/PortavozUITests/LibraryUITests.swift")
        let correctedSearch = try Self.contents(
            of: "Tests/PortavozTests/SegmentCorrectedTextSearchTests.swift")
        let scaleFixture = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ScaleBenchmark.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        let conditionStart = try XCTUnwrap(support.range(
            of: "func waitForUITestCondition("))
        let localeStart = try XCTUnwrap(support.range(
            of: "enum UITestLocale",
            range: conditionStart.upperBound..<support.endIndex))
        let conditionBody = support[
            conditionStart.lowerBound..<localeStart.lowerBound]
        XCTAssertTrue(conditionBody.contains(
            "RunLoop.current.run(until: nextProbe)"))
        XCTAssertFalse(conditionBody.contains(
            "RunLoop.current.run(mode: .default, before: nextProbe)"))
        XCTAssertFalse(conditionBody.contains("return condition()"))

        XCTAssertTrue(support.contains("var candidateFrame: CGRect?"))
        XCTAssertTrue(support.contains("stableSince = Date()"))
        XCTAssertTrue(support.contains(
            "Date().timeIntervalSince(stableSince) >= stableInterval"))
        XCTAssertFalse(support.contains("var previousFrame: CGRect?"))
        let stableFrameStart = try XCTUnwrap(support.range(
            of: "func waitForStableFrame("))
        let revealStart = try XCTUnwrap(support.range(
            of: "func revealVertically(",
            range: stableFrameStart.upperBound..<support.endIndex))
        let stableFrameBody = support[
            stableFrameStart.lowerBound..<revealStart.lowerBound]
        XCTAssertFalse(stableFrameBody.contains("waitForExistenceFast"))
        XCTAssertFalse(stableFrameBody.contains("guard self.exists else"))
        let stableFrameHittable = try XCTUnwrap(stableFrameBody.range(
            of: "guard self.isHittable else"))
        let stableFrameRead = try XCTUnwrap(stableFrameBody.range(
            of: "let currentFrame = self.frame"))
        XCTAssertLessThan(
            stableFrameHittable.lowerBound,
            stableFrameRead.lowerBound,
            "a transiently absent or obscured query must fail before reading frame")
        XCTAssertTrue(stableFrameBody.contains(
            "guard !currentFrame.isEmpty else"))
        XCTAssertFalse(stableFrameBody.contains(
            "guard !currentFrame.isEmpty, self.isHittable"))
        XCTAssertTrue(stableFrameBody.contains(
            "let stableProbeInterval = stableInterval > 0 ? stableInterval : 0.05"))
        XCTAssertTrue(stableFrameBody.contains(
            "pollInterval: stableProbeInterval"))
        XCTAssertFalse(stableFrameBody.contains(
            "return waitForUITestCondition(timeout: timeout)"))
        XCTAssertEqual(
            stableFrameBody.components(separatedBy: "self.isHittable").count - 1,
            1,
            "one guard must own both candidate-admission and acceptance samples")
        let candidateTransition = try XCTUnwrap(stableFrameBody.range(
            of: "if currentFrame != candidateFrame"))
        let stableInterval = try XCTUnwrap(stableFrameBody.range(
            of: "Date().timeIntervalSince(candidateStableSince) >= stableInterval",
            range: candidateTransition.upperBound..<stableFrameBody.endIndex))
        XCTAssertLessThan(stableFrameHittable.lowerBound, stableFrameRead.lowerBound)
        XCTAssertLessThan(stableFrameRead.lowerBound, candidateTransition.lowerBound)
        XCTAssertLessThan(candidateTransition.lowerBound, stableInterval.lowerBound)
        XCTAssertTrue(stableFrameBody.contains(
            "candidateFrame = nil\n                stableSince = nil"))

        let launchStart = try XCTUnwrap(support.range(
            of: "func launchPortavoz()"))
        let processExitStart = try XCTUnwrap(support.range(
            of: "private func waitForPortavozProcessExit(",
            range: launchStart.upperBound..<support.endIndex))
        let launchBody = support[
            launchStart.lowerBound..<processExitStart.lowerBound]
        let mainWindowStart = try XCTUnwrap(launchBody.range(
            of: "let mainWindow = windows[\"main-AppWindow-1\"]"))
        let settingsBranch = try XCTUnwrap(launchBody.range(
            of: "if shouldOpenSettings",
            range: mainWindowStart.upperBound..<launchBody.endIndex))
        let mainWindowReadiness = launchBody[
            mainWindowStart.lowerBound..<settingsBranch.lowerBound]
        XCTAssertTrue(mainWindowReadiness.contains(
            "mainWindow.waitForHittable(timeout: 15)"))
        XCTAssertFalse(mainWindowReadiness.contains("waitForExistenceFast"))
        XCTAssertFalse(mainWindowReadiness.contains("waitForStableFrame"))

        let settingsWindowStart = try XCTUnwrap(support.range(
            of: "func openSettingsWindow("))
        let settingsCategoryStart = try XCTUnwrap(support.range(
            of: "func openSettingsCategory(",
            range: settingsWindowStart.upperBound..<support.endIndex))
        let settingsWindowBody = support[
            settingsWindowStart.lowerBound..<settingsCategoryStart.lowerBound]
        XCTAssertTrue(settingsWindowBody.contains(
            "general.waitForStableFrame("))
        XCTAssertTrue(settingsWindowBody.contains("stableFor: 0.1"))
        XCTAssertEqual(settingsWindowBody.components(separatedBy:
            "identifier: \"settings-search-field\", timeout: timeout)").count - 1, 2)
        let searchEditingStart = try XCTUnwrap(settingsWindowBody.range(
            of: "private func finishSearchEditing("))
        let searchEditingBody = settingsWindowBody[searchEditingStart.lowerBound...]
        let searchClick = try XCTUnwrap(searchEditingBody.range(of: "search.click()"))
        let searchTab = try XCTUnwrap(searchEditingBody.range(
            of: "search.typeKey(.tab, modifierFlags: [])"))
        let preservedSearchValue = try XCTUnwrap(searchEditingBody.range(
            of: "search.waitForValue(originalValue, timeout: timeout)"))
        XCTAssertLessThan(searchClick.lowerBound, searchTab.lowerBound)
        XCTAssertLessThan(searchTab.lowerBound, preservedSearchValue.lowerBound)
        XCTAssertFalse(searchEditingBody.contains(".typeText("))
        XCTAssertFalse(searchEditingBody.contains(".escape"))
        XCTAssertFalse(searchEditingBody.contains("UserDefaults"))
        XCTAssertFalse(searchEditingBody.contains("SafariPlatformSupport"))

        let seededSettleStart = try XCTUnwrap(support.range(
            of: "func waitForSeededLibraryToSettle("))
        let seededReadyStart = try XCTUnwrap(support.range(
            of: "func waitForSeedFixtureReady(",
            range: seededSettleStart.upperBound..<support.endIndex))
        let categoryBody = support[
            settingsCategoryStart.lowerBound..<seededSettleStart.lowerBound]
        XCTAssertTrue(categoryBody.contains(
            "category.waitForHittable(timeout: timeout)"))
        XCTAssertFalse(categoryBody.contains("category.waitForStableFrame"))
        let seededSettleBody = support[
            seededSettleStart.lowerBound..<seededReadyStart.lowerBound]
        // Settling still means hittable, never merely present. D500 adds the
        // scroll that reaches a row below the fold on a shorter hosted window,
        // and the explanation the helper gives when it gives up.
        XCTAssertTrue(seededSettleBody.contains(
            "meeting.waitForHittable(timeout: timeout)"))
        XCTAssertTrue(seededSettleBody.contains(
            "identifier: \"library-search-field\", timeout: timeout)"))
        XCTAssertFalse(seededSettleBody.contains(
            "meeting.waitForExistenceFast"))
        XCTAssertTrue(seededSettleBody.contains(
            "scrollSidebarRowIntoView(meeting)"))
        XCTAssertTrue(seededSettleBody.contains("XCTFail("))

        let containedFrameStart = try XCTUnwrap(support.range(
            of: "private func waitForStableContainedFrame("))
        let screenshotStart = try XCTUnwrap(support.range(
            of: "extension XCTestCase",
            range: containedFrameStart.upperBound..<support.endIndex))
        let containedFrameBody = support[
            containedFrameStart.lowerBound..<screenshotStart.lowerBound]
        XCTAssertTrue(containedFrameBody.contains(
            "let stableProbeInterval = stableInterval > 0 ? stableInterval : 0.05"))
        XCTAssertTrue(containedFrameBody.contains(
            "pollInterval: stableProbeInterval"))

        let screenshotExtension = support[screenshotStart.lowerBound..<support.endIndex]
        XCTAssertFalse(screenshotExtension.contains(
            "must exist before capturing evidence"))
        XCTAssertEqual(
            screenshotExtension.components(separatedBy: ".screenshot()").count - 1,
            2,
            "the screenshot request itself must own each static evidence snapshot")

        XCTAssertTrue(skills.contains(
            "the live pane must expose the seven-action candidate catalogue"))
        XCTAssertTrue(skills.contains(
            "testSkillActivityTransitionsHideStaleRowsAndKeepVerifiedControlsUsable"))
        XCTAssertTrue(skills.contains(
            "testSkillActivityFiltersByUpdatePeriodAndResetsExpansion"))
        XCTAssertFalse(skills.contains("assertReceiptScopes"))
        XCTAssertEqual(
            skills.components(separatedBy: "auditSkillDescriptions(in: app)").count - 1,
            1,
            "one audit with the receipt sheet open already covers every app window")
        let skillsLines = skills.split(
            separator: "\n",
            omittingEmptySubsequences: false)
        for (index, line) in skillsLines.enumerated()
        where line.contains(".waitForStableFrame(timeout: 5)") {
            let priorStart = max(0, index - 2)
            let priorLines = skillsLines[priorStart..<index]
            XCTAssertFalse(
                priorLines.contains { $0.contains("scrollToVisible(") },
                "a contained Settings control must use one hittability proof")
        }
        let scrollStart = try XCTUnwrap(skills.range(
            of: "private func scrollToVisible("))
        let viewportStart = try XCTUnwrap(skills.range(
            of: "private func skillsScrollViewport(",
            range: scrollStart.upperBound..<skills.endIndex))
        let scrollBody = skills[scrollStart.lowerBound..<viewportStart.lowerBound]
        XCTAssertFalse(
            scrollBody.contains("let isVisible ="),
            "visibility must not be resampled separately from the scroll attempt")
        XCTAssertTrue(scrollBody.contains("for _ in 0..<6"))
        XCTAssertTrue(scrollBody.contains(
            "let magnitude = min(max(max(distance, abs(deltaY)), 240), 900)"))
        XCTAssertTrue(scrollBody.contains("skillsScrollViewport(in: app)"))
        XCTAssertFalse(scrollBody.contains("app.windows.containing"))

        let isOnStart = try XCTUnwrap(skills.range(
            of: "private static func isOn(",
            range: viewportStart.upperBound..<skills.endIndex))
        let viewportBody = skills[
            viewportStart.lowerBound..<isOnStart.lowerBound]
        let cachedReturn = try XCTUnwrap(viewportBody.range(
            of: "if let cachedScrollViewport { return cachedScrollViewport }"))
        let windowQuery = try XCTUnwrap(viewportBody.range(
            of: "let window = app.windows.containing"))
        XCTAssertLessThan(cachedReturn.lowerBound, windowQuery.lowerBound)
        XCTAssertEqual(
            skills.components(separatedBy: "cachedScrollViewport = nil").count - 1,
            2,
            "opening or closing Settings must invalidate the cached viewport")

        // Runtime qualification and real-app state assertions own observation
        // behavior. Attribute-read spelling would reject an equivalent atomic
        // snapshot while proving neither reachability nor the observed value.

        XCTAssertFalse(
            meeting.contains("library-search-field"),
            "structural search belongs to real-store tests plus the Library journey")
        XCTAssertEqual(
            meeting.components(separatedBy:
                "correctionEditor.waitForDisappearance(timeout: 5)").count - 1,
            2,
            "structural undo must publish terminal dismissal before row resolution")
        for owner in [
            "testMergeSearchesAcrossAcceptedBoundariesWithOrderedProvenance",
            "testRestoreAfterMergeRemovesStructuralIdentityAndReactivatesSources",
            "testSuppressedSegmentStaysOutOfSearchEntirely",
        ] {
            XCTAssertTrue(correctedSearch.contains(owner), owner)
        }
        XCTAssertTrue(library.contains("testSeededMeetingsGroupByRecency"))
        let recencyJourneyStart = try XCTUnwrap(library.range(
            of: "func testSeededMeetingsGroupByRecency()"))
        let recencyJourneyEnd = try XCTUnwrap(library.range(
            of: "func testAskConversationAnswersAndSeeksToExactCitation()",
            range: recencyJourneyStart.upperBound..<library.endIndex))
        let recencyJourney = library[
            recencyJourneyStart.lowerBound..<recencyJourneyEnd.lowerBound]
        XCTAssertEqual(recencyJourney.components(separatedBy:
            "search.waitForValue(\"viernes\", timeout: 5)").count - 1, 2)
        let endSearchEdit = try XCTUnwrap(recencyJourney.range(
            of: "search.typeKey(.tab, modifierFlags: [])"))
        let selectSearchHit = try XCTUnwrap(recencyJourney.range(of: "hit.click()"))
        XCTAssertLessThan(endSearchEdit.lowerBound, selectSearchHit.lowerBound)
        XCTAssertTrue(recencyJourney.contains("hit.waitForHittable(timeout: 5)"))
        XCTAssertTrue(library.contains("library-search-hit-"))

        XCTAssertTrue(meeting.contains("skill-receipt-email-recap-draft"))
        XCTAssertTrue(meeting.contains("handoff requested"))
        XCTAssertFalse(meeting.contains(
            "settings-skill-receipt-email-recap-draft"))
        XCTAssertTrue(meeting.contains(
            "settings-skill-receipt-secret-gist-publish"))
        XCTAssertTrue(meeting.contains(
            "settings-skill-receipt-github-issue-create"))

        XCTAssertEqual(
            meeting.components(separatedBy: "scaleAutoSummaryUpdate: true").count - 1,
            1,
            "one scale journey owns live summary replacement")
        XCTAssertTrue(meeting.contains("Scale baseline summary revision 1."))
        XCTAssertTrue(meeting.contains("continueFeatureUITestHandshake("))
        XCTAssertTrue(scaleFixture.contains("-scale-auto-summary-handshake"))
        XCTAssertTrue(scaleFixture.contains(
            "PORTAVOZ_UI_TEST_SCALE_SUMMARY_READY_PATH"))
        XCTAssertFalse(scaleFixture.contains(
            "Task.sleep(for: .seconds(3))"))
        XCTAssertTrue(meeting.contains(
            #"named: "meeting-detail-scale-5000-segments""#))
        XCTAssertFalse(meeting.contains(
            #"named: "meeting-detail-scale-20000-segments""#))
        XCTAssertEqual(
            meeting.components(separatedBy: "waitForSeedFixtureReady(timeout: 45)").count - 1,
            2,
            "both detail-scale journeys wait for the complete disposable aggregate")
        XCTAssertTrue(support.contains("portavoz-scale-ready-"))
        XCTAssertTrue(scaleFixture.contains("defer { markUITestSeedReady() }"))
        XCTAssertFalse(scaleFixture.contains("requestSearchReconciliation()"))
        XCTAssertTrue(meeting.contains("ownerPickers.count"))
        XCTAssertTrue(meeting.contains(
            "editor.descendants(matching: .popUpButton)"))

        let reviewJourneyStart = try XCTUnwrap(meeting.range(
            of: "func testMeetingReviewSurfacesRemainCompleteAndActionable()"))
        let evidenceJourneyStart = try XCTUnwrap(meeting.range(
            of: "func testEvidenceSourcesJumpToTheirExactTranscriptAndAudio()",
            range: reviewJourneyStart.upperBound..<meeting.endIndex))
        let reviewJourney = meeting[
            reviewJourneyStart.lowerBound..<evidenceJourneyStart.lowerBound]
        for evidenceName in [
            "meeting-detail-my-notes",
            "meeting-detail-privacy-receipt",
            "meeting-detail-transcript-navigation",
            "meeting-detail-generated-document",
        ] {
            XCTAssertTrue(reviewJourney.contains(evidenceName), evidenceName)
        }
        for semanticBoundary in [
            "let notesSection = app.control(withIdentifier: \"detail-notes-section\")",
            "let secondaryRail = app.control(withIdentifier: \"detail-secondary-rail\")",
            "let generatedDocument = app.control(withIdentifier: \"detail-generated-document\")",
        ] {
            XCTAssertTrue(reviewJourney.contains(semanticBoundary), semanticBoundary)
        }
        XCTAssertTrue(reviewJourney.contains(
            "generatedDocument.descendants(matching: .any)"))
        XCTAssertTrue(reviewJourney.contains(
            "guard actionItem.waitForStableFrame(timeout: 10)"))
        XCTAssertTrue(reviewJourney.contains(
            "names: [\n"
                + "                \"meeting-detail-privacy-receipt\",\n"
                + "                \"meeting-detail-transcript-navigation\","))
        XCTAssertEqual(
            support.components(
                separatedBy: "let screenshot = window.screenshot()").count - 1,
            1,
            "named evidence aliases must reuse one immutable window capture")

        let decisionJourneyStart = try XCTUnwrap(meeting.range(
            of: "func testDecisionCanBeConfirmedAboutATopic()",
            range: evidenceJourneyStart.upperBound..<meeting.endIndex))
        let evidenceJourney = meeting[
            evidenceJourneyStart.lowerBound..<decisionJourneyStart.lowerBound]
        for evidenceName in [
            "meeting-detail-summary-evidence",
            "meeting-detail-decision-evidence",
            "meeting-detail-action-item-evidence",
            "meeting-detail-apuntador-evidence",
        ] {
            XCTAssertTrue(evidenceJourney.contains(evidenceName), evidenceName)
        }
        XCTAssertEqual(
            evidenceJourney.components(
                separatedBy: "resetEvidenceNavigation(").count - 1,
            3,
            "later source checks must first move to a distinguishable transcript target")
        for retiredJourney in [
            "testTabbedSummaryRevealsTheCoauthoringBullet",
            "testMyNotesSectionShowsRawNotesAndOffersEnhancement",
            "testSummarySourceJumpsToItsTranscriptAndAudio",
            "testDecisionSourceJumpsToItsTranscriptAndAudio",
            "testActionItemSourceJumpsToItsTranscriptAndAudio",
            "testApuntadorAnswerSourceJumpsToItsTranscriptAndAudio",
            "testRightRailShowsHealthAndChapters",
        ] {
            XCTAssertFalse(meeting.contains(retiredJourney), retiredJourney)
        }

        XCTAssertTrue(decisions.contains("## D410"))
        XCTAssertTrue(decisions.contains("## D411"))
        XCTAssertTrue(decisions.contains("## D412"))
        XCTAssertTrue(decisions.contains("## D417"))
        XCTAssertTrue(decisions.contains("## D418"))
        XCTAssertTrue(decisions.contains("## D419"))
        XCTAssertTrue(decisions.contains("## D420"))
        XCTAssertTrue(decisions.contains("## D421"))
        XCTAssertTrue(decisions.contains("## D422"))
        XCTAssertTrue(decisions.contains("## D424"))
    }

    func testDistributionNotarizesTheExtractedAppBeforeTheDMG() throws {
        let builder = try Self.contents(of: "scripts/make-dmg.sh")
        let verifier = try Self.contents(of: "scripts/verify-distribution.sh")

        let archive = try XCTUnwrap(builder.range(of: "ditto -c -k --sequesterRsrc"))
        let appSubmission = try XCTUnwrap(builder.range(
            of: "notarytool submit \"$APP_ARCHIVE\"", range: archive.upperBound..<builder.endIndex))
        let appStaple = try XCTUnwrap(builder.range(
            of: "stapler staple dist/Portavoz.app",
            range: appSubmission.upperBound..<builder.endIndex))
        let package = try XCTUnwrap(builder.range(
            of: "cp -a dist/Portavoz.app \"$STAGE/\"",
            range: appStaple.upperBound..<builder.endIndex))
        let imageSubmission = try XCTUnwrap(builder.range(
            of: "notarytool submit \"$DMG\"", range: package.upperBound..<builder.endIndex))
        let imageStaple = try XCTUnwrap(builder.range(
            of: "stapler staple \"$DMG\"",
            range: imageSubmission.upperBound..<builder.endIndex))
        XCTAssertNotNil(builder.range(
            of: "scripts/verify-distribution.sh \"$DMG\"",
            range: imageStaple.upperBound..<builder.endIndex))

        XCTAssertTrue(verifier.contains("cp -a \"$MOUNT/Portavoz.app\" \"$APP_COPY\""))
        XCTAssertTrue(verifier.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(verifier.contains("stapler validate \"$APP_COPY\""))
        XCTAssertTrue(verifier.contains("spctl -a -vvv -t exec \"$APP_COPY\""))
        XCTAssertTrue(verifier.contains(
            "scripts/verify-cloudkit-capabilities.sh \"$APP_COPY\""))
    }

    func testReleaseReliabilityLedgerIsFailClosedAndContentFree() throws {
        let contract = try Self.jsonObject(
            at: "docs/evidence/reliability-gates.json")
        let proofs = try XCTUnwrap(contract["proofs"] as? [[String: Any]])
        XCTAssertEqual(contract["schemaVersion"] as? Int, 2)
        XCTAssertEqual(proofs.count, 29)
        XCTAssertEqual(
            Set(proofs.compactMap { $0["class"] as? String }),
            Set([
                "deterministic-automated",
                "candidate-automated",
                "source-integration",
                "signed-build",
                "production-sync",
                "real-hardware",
                "assistive-technology",
                "user-field",
            ]))

        let evaluator = try Self.contents(of: "scripts/release_reliability.py")
        let sourceIntegration = try Self.contents(
            of: "scripts/source_integration_qualification.py")
        let sourceIntegrationWorkflow = try Self.contents(
            of: ".github/workflows/source-integration-evidence.yml")
        let sourceIntegrationContract = try Self.jsonObject(
            at: "docs/evidence/source-integration-qualification.json")
        let runner = try Self.contents(
            of: "scripts/run-release-reliability-gates.sh")
        let failureSummary = try Self.contents(
            of: "scripts/swift_test_failure_summary.py")
        let correctionScale = try Self.contents(
            of: "Tests/PortavozTests/TranscriptCorrectionScaleBenchmarkTests.swift")
        let correctionComposer = try Self.contents(
            of: "Sources/ApplicationKit/ComposeTranscript.swift")
        let verifier = try Self.contents(of: "scripts/verify-distribution.sh")
        let packager = try Self.contents(of: "scripts/make-app.sh")
        let releaseScript = try Self.contents(of: "scripts/make-release.sh")
        let appcastVerifier = try Self.contents(
            of: "scripts/verify_release_appcast.py")
        let hygiene = try Self.contents(
            of: "scripts/check-repository-hygiene.sh")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(evaluator.contains(
            #"outcome = "pass" if all(row["state"] == "pass""#))
        XCTAssertTrue(evaluator.contains(
            #""not-observed" if root["outcome"] == "incomplete""#))
        XCTAssertTrue(evaluator.contains(
            #""The scorecard contains no meeting content.""#))
        XCTAssertTrue(evaluator.contains("QUALIFICATION_RECEIPTS"))
        XCTAssertTrue(evaluator.contains("def validate_qualification_authority("))
        XCTAssertTrue(evaluator.contains("canonical_document_sha256(authority)"))
        XCTAssertTrue(evaluator.contains(
            #""artifact": ("#))
        XCTAssertEqual(sourceIntegrationContract["schemaVersion"] as? Int, 1)
        XCTAssertEqual(
            sourceIntegrationContract["kind"] as? String,
            "source-integration-qualification-contract")
        XCTAssertTrue(sourceIntegration.contains("GitHub API"))
        XCTAssertTrue(sourceIntegration.contains("workflow_dispatch"))
        XCTAssertTrue(sourceIntegration.contains("run_attempt"))
        XCTAssertTrue(sourceIntegration.contains("CHANGES_REQUESTED"))
        XCTAssertTrue(sourceIntegration.contains("source-integration"))
        XCTAssertTrue(sourceIntegration.contains("authoritySHA256"))
        XCTAssertTrue(sourceIntegration.contains("os.replace(prepared, output)"))
        XCTAssertFalse(sourceIntegration.contains("--proof"))
        XCTAssertFalse(sourceIntegration.contains("--contract"))
        XCTAssertTrue(sourceIntegrationWorkflow.contains("actions: read"))
        XCTAssertTrue(sourceIntegrationWorkflow.contains("contents: read"))
        XCTAssertTrue(sourceIntegrationWorkflow.contains("pull-requests: read"))
        XCTAssertTrue(sourceIntegrationWorkflow.contains(
            "PORTAVOZ_RELEASE_COMMIT: ${{ inputs.commit }}"))
        XCTAssertTrue(sourceIntegrationWorkflow.contains(
            "if: github.ref == 'refs/heads/main'"))
        XCTAssertTrue(sourceIntegrationWorkflow.contains("ref: main"))
        XCTAssertFalse(sourceIntegrationWorkflow.contains(
            "ref: ${{ inputs.commit }}"))
        XCTAssertFalse(sourceIntegrationWorkflow.contains("pull_request_target"))
        XCTAssertFalse(sourceIntegrationWorkflow.contains(
            "--commit '${{ inputs.commit }}'"))
        XCTAssertTrue(runner.contains("PORTAVOZ_RELEASE_VERSION"))
        XCTAssertTrue(runner.contains("make test-recording-stress"))
        XCTAssertTrue(runner.contains("make test-ui-scoped"))
        XCTAssertTrue(runner.contains("umask 077"))
        XCTAssertTrue(runner.contains("mktemp -d"))
        XCTAssertTrue(runner.contains("swift test 2>&1 | tee"))
        XCTAssertTrue(runner.contains(#"pipeline_status=("${PIPESTATUS[@]}")"#))
        XCTAssertTrue(runner.contains("swift_test_failure_summary.py"))
        XCTAssertFalse(runner.contains("swift test --xunit-output"))
        XCTAssertTrue(runner.contains(
            "PORTAVOZ_CORRECTION_COMPOSITION_RUNS=20"))
        XCTAssertTrue(runner.contains("make correction-composition-benchmark"))
        XCTAssertTrue(failureSummary.contains("MAXIMUM_LOG_BYTES"))
        XCTAssertTrue(failureSummary.contains("failed_test="))
        XCTAssertFalse(failureSummary.contains("print(text"))
        XCTAssertTrue(correctionScale.contains(
            "testDenseCorrectionHistoryComposesStablyOutsideTimedGate"))
        XCTAssertTrue(correctionScale.contains(
            "CorrectionCompositionBenchmark.measure(options:"))
        XCTAssertTrue(correctionScale.contains(
            "CorrectionCompositionBenchmark.run(options: options)"))
        XCTAssertEqual(
            correctionComposer.components(
                separatedBy:
                    "TranscriptCorrectionDomainIndex(history: history)"
            ).count,
            3)
        XCTAssertFalse(correctionComposer.contains(
            "TranscriptCorrectionPolicy.correctionDomain("))
        XCTAssertTrue(verifier.contains("record-distribution"))
        XCTAssertTrue(verifier.contains("PortavozSourceCommit"))
        XCTAssertTrue(verifier.contains("--commit \"$SOURCE_COMMIT\""))
        XCTAssertTrue(packager.contains(
            "plutil -insert PortavozSourceCommit -string \"$SOURCE_COMMIT\""))
        XCTAssertTrue(releaseScript.contains(
            "SOURCE_COMMIT=\"${PORTAVOZ_RELEASE_COMMIT:?"))
        XCTAssertTrue(releaseScript.contains(
            "git status --porcelain --untracked-files=no"))
        XCTAssertTrue(releaseScript.contains(
            "PORTAVOZ_RELEASE_COMMIT=\"$SOURCE_COMMIT\""))
        let signerPreflight = try XCTUnwrap(releaseScript.range(
            of: "if [[ ! -x \"$GENERATE_APPCAST\" ]]"))
        let appBuild = try XCTUnwrap(releaseScript.range(
            of: "scripts/make-app.sh --release"))
        XCTAssertLessThan(signerPreflight.lowerBound, appBuild.lowerBound)
        let appcastGeneration = try XCTUnwrap(releaseScript.range(
            of: "\"$GENERATE_APPCAST\" --account portavoz"))
        let appcastVerification = try XCTUnwrap(releaseScript.range(
            of: "scripts/verify_release_appcast.py"))
        let caskRendering = try XCTUnwrap(releaseScript.range(
            of: "# Homebrew cask with real version + sha256."))
        XCTAssertLessThan(appcastGeneration.lowerBound, appcastVerification.lowerBound)
        XCTAssertLessThan(appcastVerification.lowerBound, caskRendering.lowerBound)
        XCTAssertTrue(appcastVerifier.contains("SPARKLE_NAMESPACE"))
        XCTAssertTrue(appcastVerifier.contains("actual_version != version"))
        XCTAssertTrue(appcastVerifier.contains("actual_build != build"))
        XCTAssertTrue(appcastVerifier.contains("enclosure.get(\"url\")"))
        XCTAssertTrue(appcastVerifier.contains("enclosure.get(\"length\")"))
        XCTAssertTrue(appcastVerifier.contains("edSignature"))
        XCTAssertTrue(appcastVerifier.contains("base64.b64decode"))
        XCTAssertEqual(
            releaseScript.components(
                separatedBy: "require_exact_source_checkout").count,
            4)
        XCTAssertTrue(verifier.contains("--receipt"))
        XCTAssertTrue(hygiene.contains(
            "Tests.Tooling.test_release_reliability"))
        XCTAssertTrue(hygiene.contains(
            "Tests.Tooling.test_make_release"))
        XCTAssertTrue(hygiene.contains(
            "Tests.Tooling.test_source_integration_qualification"))
        XCTAssertTrue(hygiene.contains(
            "Tests.Tooling.test_swift_test_failure_summary"))
        XCTAssertTrue(hygiene.contains(
            "bash -n scripts/run-release-reliability-gates.sh"))
        XCTAssertTrue(hygiene.contains(
            "bash -n scripts/make-release.sh"))
        XCTAssertTrue(decisions.contains("## D147"))
        XCTAssertTrue(decisions.contains("## D391"))
        XCTAssertTrue(decisions.contains("## D394"))
        XCTAssertTrue(decisions.contains("## D395"))
        XCTAssertTrue(decisions.contains("## D402"))
        XCTAssertTrue(decisions.contains("## D445"))
    }

    func testCandidateAutomationOwnsEightSpecializedProofs() throws {
        let contract = try Self.jsonObject(
            at: "docs/evidence/candidate-automation.json")
        XCTAssertEqual(contract["schemaVersion"] as? Int, 9)
        XCTAssertEqual(
            contract["kind"] as? String,
            "candidate-automation-contract")
        XCTAssertEqual(
            contract["proofs"] as? [String],
            [
                "finite-scope",
                "autonomous-validation",
                "model-gated",
                "performance-ledger",
                "resource-baseline",
                "long-capture",
                "upgrade-recovery",
                "complete-bilingual-ui",
            ])

        let performance = try XCTUnwrap(
            contract["performance"] as? [String: Any])
        let measured = Set(try XCTUnwrap(
            performance["requiredMeasuredMetricIDs"] as? [String]))
        let unmeasured = Set(try XCTUnwrap(
            performance["allowedNotMeasuredMetricIDs"] as? [String]))
        XCTAssertEqual(measured.count, 12)
        XCTAssertEqual(unmeasured.count, 13)
        XCTAssertTrue(measured.isDisjoint(with: unmeasured))
        XCTAssertEqual(performance["confirmationRuns"] as? Int, 3)
        XCTAssertEqual(
            performance["binaryPolicy"] as? String,
            "single-exact-release-build-sha256-v1")
        let hostReadiness = try XCTUnwrap(
            performance["hostReadiness"] as? [String: Any])
        XCTAssertEqual(
            hostReadiness["version"] as? String,
            "prebuilt-release-host-readiness-v5")
        XCTAssertEqual(hostReadiness["maximumWaitSeconds"] as? Double, 300)
        XCTAssertEqual(hostReadiness["sampleIntervalSeconds"] as? Double, 0.5)
        XCTAssertEqual(hostReadiness["requiredConsecutiveSamples"] as? Int, 10)
        XCTAssertEqual(hostReadiness["requiresNoPortavozApp"] as? Bool, true)
        XCTAssertEqual(
            hostReadiness["maximumInterferenceCPUPercent"] as? Double,
            2)
        XCTAssertEqual(
            hostReadiness["recognizedInterferenceClasses"] as? [String],
            [
                "browser-automation",
                "build-driver",
                "clang-compiler",
                "container-virtualization",
                "external-build-runtime",
                "javascript-runtime",
                "linker",
                "media-processing",
                "source-analysis",
                "swift-compiler",
                "symbolication",
            ])
        let throughputCalibration = try XCTUnwrap(
            hostReadiness["throughputCalibration"] as? [String: Any])
        XCTAssertEqual(
            throughputCalibration["version"] as? String,
            "sha256-zero-block-512mib-v1")
        XCTAssertEqual(throughputCalibration["sampleCount"] as? Int, 5)
        XCTAssertEqual(
            throughputCalibration["bytesPerSample"] as? Int,
            536_870_912)
        XCTAssertEqual(
            throughputCalibration["maximumWallMilliseconds"] as? Double,
            200)
        XCTAssertEqual(
            throughputCalibration["maximumCPUMilliseconds"] as? Double,
            200)
        XCTAssertEqual(
            throughputCalibration["maximumDispersionRatio"] as? Double,
            1.15)
        let modelFixture = try XCTUnwrap(
            contract["modelFixture"] as? [String: Any])
        XCTAssertEqual(
            modelFixture["text"] as? String,
            "Fixtures/CandidateAutomation/public-model-lane-en-v1.txt")
        XCTAssertEqual(modelFixture["systemVoice"] as? String, "Samantha")
        XCTAssertEqual(
            modelFixture["conversationText"] as? String,
            "Fixtures/CandidateAutomation/public-diarization-en-es-v1.txt")
        XCTAssertEqual(
            modelFixture["conversationVoices"] as? [String],
            ["Daniel", "Paulina"])
        let memoryLeaks = try XCTUnwrap(
            contract["memoryLeaks"] as? [String: Any])
        XCTAssertEqual(
            memoryLeaks["contract"] as? String,
            "docs/evidence/apuntador-leak-baseline.json")
        XCTAssertEqual(
            memoryLeaks["scenarioIterations"] as? [String: Int],
            [
                "live-assist-released": 100,
                "live-assist-bundled-question": 100,
                "ask": 10,
                "semantic-indexing": 10,
            ])
        XCTAssertEqual(
            memoryLeaks["requiredScenarios"] as? [String],
            [
                "live-assist-released",
                "live-assist-bundled-question",
                "ask",
                "semantic-indexing",
            ])

        let runner = try Self.contents(of: "scripts/candidate_automation.py")
        let performanceRunner = try Self.contents(
            of: "scripts/run-perf-ledger.sh")
        let performanceBinary = try Self.contents(
            of: "scripts/perf-binary.sh")
        let performanceReadiness = try Self.contents(
            of: "scripts/perf_host_readiness.py")
        let scaleRunner = try Self.contents(
            of: "scripts/run-scale-baseline.sh")
        let semanticRunner = try Self.contents(
            of: "scripts/run-semantic-scale-baseline.sh")
        let spotlightRunner = try Self.contents(
            of: "scripts/run-spotlight-scale-baseline.sh")
        let leakRunner = try Self.contents(
            of: "scripts/run-apuntador-leak-baseline.sh")
        let leakValidator = try Self.contents(
            of: "scripts/apuntador_leak_baseline.py")
        let makefile = try Self.contents(of: "Makefile")
        let hygiene = try Self.contents(
            of: "scripts/check-repository-hygiene.sh")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let diarizationTests = try Self.contents(
            of: "Tests/PortavozTests/DiarizationTests.swift")
        let embeddingTests = try Self.contents(
            of: "Tests/PortavozTests/RAGTests.swift")
        for required in [
            "scripts/run-release-reliability-gates.sh",
            "make\", \"test-apuntador-validation",
            "scripts/run-perf-ledger.sh",
            "run_candidate_performance_gate",
            "build_candidate_performance_binary",
            "Exact performance Release build",
            "PORTAVOZ_PERF_BINARY_SHA256",
            "PORTAVOZ_PERF_HOST_MAXIMUM_INTERFERENCE_CPU_PERCENT",
            "PORTAVOZ_PERF_HOST_MAXIMUM_CALIBRATION_WALL_MILLISECONDS",
            "performance-regression-confirmation",
            "accepted_exit_codes=(0, 2)",
            "PORTAVOZ_PERF_STRICT\": \"0",
            "scripts/run-resource-baseline.sh",
            "scripts/run-apuntador-leak-baseline.sh",
            "scripts/run-long-capture-baseline.sh",
            "make\", \"test-ui-bilingual",
            "validate_performance_ledger",
            "validate_resource_receipt",
            "validate_memory_leak_receipt",
            "validate_long_capture",
            "validate_ui_receipts",
            "validate_public_model_fixture",
            "render_public_conversation",
            "EXPECTED_CONVERSATION_SEQUENCE",
            "--data-format=LEI16@16000",
            "MINIMUM_CONVERSATION_DURATION_SECONDS",
            "PORTAVOZ_MODEL_TESTS\": \"1",
            "PORTAVOZ_PERF_WAVEFORM_MIC\": None",
            "PORTAVOZ_SIGN_IDENTITY\": \"-",
            "candidate qualification requires a completely clean worktree",
        ] {
            XCTAssertTrue(runner.contains(required), "missing \(required)")
        }
        XCTAssertFalse(runner.contains("--proof"))
        XCTAssertFalse(runner.contains("record-qualification"))
        XCTAssertFalse(diarizationTests.contains("ensureAvailable("))
        XCTAssertTrue(diarizationTests.contains(
            "report.isComplete"))
        XCTAssertTrue(diarizationTests.contains(
            "store.directory(for: descriptor)"))
        XCTAssertTrue(embeddingTests.contains(
            "embedder.prepare(allowAssetDownload: false)"))
        XCTAssertTrue(makefile.contains("candidate-automation:"))
        XCTAssertTrue(makefile.contains("test-apuntador-leak-baseline:"))
        XCTAssertTrue(makefile.contains("apuntador-leak-baseline:"))
        XCTAssertTrue(leakRunner.contains("ITERATIONS=100"))
        XCTAssertTrue(leakRunner.contains(
            "--live-assist-iterations must match the fixed value 100"))
        XCTAssertTrue(leakValidator.contains("SCHEMA_VERSION = 3"))
        XCTAssertTrue(leakValidator.contains(
            "\"ask\": 10"))
        XCTAssertTrue(leakValidator.contains(
            "live-assist evidence iteration count does not match the contract"))
        XCTAssertTrue(leakValidator.contains(
            "live_assist_validation.LiveAssistValidationError, OSError"))
        XCTAssertTrue(leakValidator.contains(
            "leak evidence could not be hashed"))
        XCTAssertTrue(makefile.contains(
            "release-reliability long-capture-baseline candidate-automation"))
        XCTAssertTrue(hygiene.contains(
            "Tests.Tooling.test_candidate_automation"))
        XCTAssertTrue(hygiene.contains(
            "Tests.Tooling.test_perf_binary"))
        XCTAssertTrue(hygiene.contains(
            "Tests.Tooling.test_perf_host_readiness"))
        XCTAssertTrue(hygiene.contains(
            "Tests.Tooling.test_apuntador_leak_baseline"))
        XCTAssertTrue(decisions.contains("## D392"))
        XCTAssertTrue(decisions.contains("## D393"))
        XCTAssertTrue(decisions.contains("## D401"))
        XCTAssertTrue(decisions.contains("## D447"))
        XCTAssertTrue(decisions.contains("## D448"))
        XCTAssertTrue(decisions.contains("## D449"))
        XCTAssertTrue(decisions.contains("## D450"))
        XCTAssertTrue(decisions.contains("## D454"))
        XCTAssertTrue(decisions.contains("## D456"))
        XCTAssertTrue(decisions.contains("## D460"))
        XCTAssertTrue(decisions.contains("## D462"))
        XCTAssertTrue(decisions.contains("## D466"))
        XCTAssertTrue(decisions.contains("## D467"))
        XCTAssertTrue(performanceRunner.contains(
            "run_host_readiness \"Scale\""))
        XCTAssertTrue(performanceRunner.contains(
            "host-readiness-semantic.json"))
        XCTAssertTrue(performanceRunner.contains(
            "host-readiness-spotlight.json"))
        XCTAssertTrue(performanceRunner.contains(
            "portavoz_prepare_perf_binary"))
        XCTAssertTrue(performanceRunner.contains(
            "host-readiness.json"))
        XCTAssertTrue(performanceRunner.contains(
            "PORTAVOZ_PERF_HOST_SAMPLE_INTERVAL_SECONDS:-0.5"))
        XCTAssertTrue(performanceRunner.contains(
            "PORTAVOZ_PERF_HOST_REQUIRED_CONSECUTIVE_SAMPLES:-10"))
        XCTAssertTrue(performanceBinary.contains(
            "performance binary changed after the exact Release build"))
        XCTAssertTrue(performanceReadiness.contains(
            "required_consecutive_samples"))
        XCTAssertTrue(performanceReadiness.contains(
            "recognized-interference"))
        XCTAssertTrue(performanceReadiness.contains(
            "SCHEMA_VERSION = 5"))
        XCTAssertTrue(performanceReadiness.contains(
            "prebuilt-release-host-readiness-v5"))
        XCTAssertTrue(performanceReadiness.contains(
            "sha256-zero-block-512mib-v1"))
        XCTAssertTrue(performanceReadiness.contains(
            "interferenceContributors"))
        XCTAssertTrue(performanceReadiness.contains(
            "INTERFERENCE_CLASSES"))
        XCTAssertTrue(performanceReadiness.contains(
            "activePortavozAppCount"))
        XCTAssertTrue(performanceReadiness.contains(
            "portavoz-app-active"))
        for harness in [scaleRunner, semanticRunner, spotlightRunner] {
            XCTAssertTrue(harness.contains("PORTAVOZ_PERF_BINARY"))
            XCTAssertFalse(harness.contains(
                "swift build -c release --product portavoz-cli"))
        }
    }

    func testDevInstallVerifiesTheSignedBundleBeforeLaunchingIt() throws {
        let packager = try Self.contents(of: "scripts/make-app.sh")
        let makefile = try Self.contents(of: "Makefile")

        let packageSign = try XCTUnwrap(packager.range(
            of: "--entitlements \"$SIGN_ENTITLEMENTS\" \"$APP\""))
        let packageVerify = try XCTUnwrap(packager.range(
            of: "codesign --verify --deep --strict --verbose=2 \"$APP\"",
            range: packageSign.upperBound..<packager.endIndex))
        XCTAssertNotNil(packager.range(
            of: "echo \"OK → $APP",
            range: packageVerify.upperBound..<packager.endIndex))

        let resign = try XCTUnwrap(makefile.range(
            of: "codesign --force --options runtime --timestamp"))
        let devIdentity = try XCTUnwrap(makefile.range(
            of: "CFBundleIdentifier -string \"app.portavoz.mac.dev\"",
            range: makefile.startIndex..<resign.lowerBound))
        XCTAssertNotNil(makefile.range(
            of: "CFBundleDisplayName -string \"Portavoz Dev\"",
            range: makefile.startIndex..<devIdentity.lowerBound))
        XCTAssertNotNil(makefile.range(
            of: #"s/^"CFBundleDisplayName" = ".*""#,
            range: devIdentity.upperBound..<resign.lowerBound))
        XCTAssertNotNil(makefile.range(
            of: "plutil -lint \"$$plist\"",
            range: devIdentity.upperBound..<resign.lowerBound))
        let verifyDist = try XCTUnwrap(makefile.range(
            of: "codesign --verify --deep --strict --verbose=2 dist/Portavoz.app",
            range: resign.upperBound..<makefile.endIndex))
        let copy = try XCTUnwrap(makefile.range(
            of: "cp -R dist/Portavoz.app \"/Applications/Portavoz Dev.app\"",
            range: verifyDist.upperBound..<makefile.endIndex))
        let verifyInstalled = try XCTUnwrap(makefile.range(
            of: "codesign --verify --deep --strict --verbose=2 "
                + "\"/Applications/Portavoz Dev.app\"",
            range: copy.upperBound..<makefile.endIndex))
        let register = try XCTUnwrap(makefile.range(
            of: "-f \"/Applications/Portavoz Dev.app\"",
            range: verifyInstalled.upperBound..<makefile.endIndex))
        XCTAssertNotNil(makefile.range(
            of: "open \"/Applications/Portavoz Dev.app\"",
            range: register.upperBound..<makefile.endIndex))
    }

    func testProductionSyncQualificationPreservesExactProvisionedIdentity() throws {
        let verifier = try Self.contents(
            of: "scripts/verify-cloudkit-capabilities.sh")
        let qualification = try Self.contents(
            of: "scripts/make-production-sync-qualification-app.sh")
        let makeApp = try Self.contents(of: "scripts/make-app.sh")
        let packagingTests = try Self.contents(
            of: "Tests/Tooling/test_production_sync_qualification_packaging.py")
        let materializer = try Self.contents(
            of: "scripts/materialize-cloudkit-entitlements.py")
        let makefile = try Self.contents(of: "Makefile")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(verifier.contains("$APP/Contents/Info.plist"))
        XCTAssertTrue(verifier.contains(
            #"expected_bundle_identifier = "app.portavoz.mac""#))
        XCTAssertTrue(verifier.contains("ApplicationIdentifierPrefix"))
        XCTAssertTrue(verifier.contains(#""application-identifier""#))
        XCTAssertTrue(verifier.contains(
            #""com.apple.application-identifier""#))
        XCTAssertTrue(verifier.contains(
            #""com.apple.developer.team-identifier""#))
        XCTAssertTrue(verifier.contains(
            "application identifier does not authorize"))
        XCTAssertTrue(verifier.contains(
            #"f"{prefix}.{expected_bundle_identifier}""#))

        XCTAssertTrue(makeApp.contains(
            "scripts/materialize-cloudkit-entitlements.py"))
        XCTAssertTrue(makeApp.contains(
            "dist/.portavoz-production.entitlements"))
        XCTAssertTrue(materializer.contains(
            #"result["com.apple.application-identifier"]"#))
        XCTAssertTrue(materializer.contains(
            #"result["com.apple.developer.team-identifier"]"#))

        XCTAssertTrue(qualification.contains(
            #"OUTPUT="dist/Portavoz Sync Qualification.app""#))
        XCTAssertTrue(qualification.contains(
            #""CFBundleIdentifier": "app.portavoz.mac""#))
        XCTAssertTrue(qualification.contains(
            "PORTAVOZ_REQUIRE_CLOUDKIT_PROFILE=1"))
        XCTAssertTrue(qualification.contains(
            "require_exact_source_checkout \"final verification\""))
        XCTAssertFalse(qualification.contains("/Applications/"))
        XCTAssertFalse(qualification.contains("lsregister"))
        XCTAssertFalse(qualification.contains("\nopen \"$OUTPUT\""))
        XCTAssertTrue(packagingTests.contains(#"plutil = tools / "plutil""#))
        XCTAssertTrue(packagingTests.contains(#"sed = tools / "sed""#))
        XCTAssertTrue(packagingTests.contains(
            "unexpected plutil replacement arguments"))
        XCTAssertTrue(packagingTests.contains("unexpected sed arguments"))

        let resign = try XCTUnwrap(qualification.range(
            of: "--entitlements \"$SIGN_ENTITLEMENTS\" \"$STAGING\""))
        let signature = try XCTUnwrap(qualification.range(
            of: "codesign --verify --deep --strict --verbose=2 \"$STAGING\"",
            range: resign.upperBound..<qualification.endIndex))
        XCTAssertNotNil(qualification.range(
            of: "scripts/verify-cloudkit-capabilities.sh \"$STAGING\"",
            range: signature.upperBound..<qualification.endIndex))

        let installGuard = try XCTUnwrap(makefile.range(
            of: "make install cannot mutate a production-profile app"))
        XCTAssertNotNil(makefile.range(
            of: "scripts/make-app.sh --release",
            range: installGuard.upperBound..<makefile.endIndex))
        XCTAssertTrue(makefile.contains("production-sync-qualification-app:"))
        XCTAssertTrue(decisions.contains("## D403"))
    }

    func testProductionSyncQualificationUsesIsolatedRealAppAndPublicCorpus() throws {
        let evidence = try Self.contents(
            of: "Sources/portavoz-app/ProductionSyncQualificationEvidence.swift")
        let corpus = try Self.contents(
            of: "Sources/portavoz-app/ProductionSyncQualificationCorpus.swift")
        let runner = try Self.contents(
            of: "Sources/portavoz-app/ProductionSyncQualificationRunner.swift")
        let process = try Self.contents(
            of: "Sources/portavoz-app/ProductionSyncQualificationProcess.swift")
        let launch = try Self.contents(
            of: "Sources/portavoz-app/AppLaunchModel.swift")
        let app = try Self.contents(of: "Sources/portavoz-app/PortavozApp.swift")
        let bench = try Self.contents(of: "Sources/portavoz-app/BenchMode.swift")
        let delegate = try Self.contents(
            of: "Sources/portavoz-app/PortavozAppDelegate.swift")

        XCTAssertTrue(evidence.contains("temporaryStoreIndexes.count == 1"))
        XCTAssertTrue(evidence.contains("forbiddenIsolationArguments.isEmpty"))
        XCTAssertTrue(evidence.contains("arguments == expected"))
        XCTAssertTrue(evidence.contains("portavozKeys == [qualificationKey]"))
        XCTAssertTrue(evidence.contains("Contents/_CodeSignature/CodeResources"))
        XCTAssertTrue(evidence.contains("Contents/embedded.provisionprofile"))
        XCTAssertTrue(process.contains("kIOPlatformUUIDKey"))
        XCTAssertTrue(process.contains("portavoz-production-sync-host-v1"))
        XCTAssertTrue(process.contains("requireSafeScratchTree"))
        XCTAssertFalse(evidence.contains("platformUUID:"))

        XCTAssertTrue(corpus.contains(
            "We approved the public qualification plan."))
        XCTAssertTrue(corpus.contains(
            "Aprobamos el plan público de calificación."))
        XCTAssertTrue(corpus.contains("audioDirectory: nil"))
        XCTAssertTrue(corpus.contains("acknowledgeMeetingSync"))

        let prerequisites = try XCTUnwrap(runner.range(
            of: "try validatePrerequisites()"))
        let predecessor = try XCTUnwrap(runner.range(
            of: "let predecessor = try predecessorDigest()"))
        XCTAssertLessThan(prerequisites.lowerBound, predecessor.lowerBound)
        XCTAssertTrue(runner.contains("CloudMeetingSyncLifecycle("))
        XCTAssertTrue(runner.contains("CloudKitMeetingSyncPlatform()"))
        XCTAssertTrue(runner.contains("workspacePath.hasPrefix(root + \"/\")"))
        XCTAssertFalse(runner.contains("workspacePath == root ||"))
        XCTAssertTrue(runner.contains("production-sync await-push READY"))
        XCTAssertTrue(runner.contains("writeLiveStageMarker()"))
        XCTAssertTrue(runner.contains("validatedLiveStageMarkerDigest()"))
        XCTAssertTrue(runner.contains("registerForRemoteNotifications()"))
        XCTAssertTrue(runner.contains("unregisterForRemoteNotifications()"))
        XCTAssertTrue(runner.contains("bufferingPolicy: .bufferingNewest("))

        XCTAssertTrue(bench.contains(
            "ProductionSyncQualificationConfiguration.isRequested"))
        let isolationGuard = try XCTUnwrap(launch.range(
            of: "guard !ProductionSyncQualificationConfiguration.isRequested"))
        let serviceConstruction = try XCTUnwrap(launch.range(
            of: "openServices()",
            range: isolationGuard.upperBound..<launch.endIndex))
        XCTAssertLessThan(isolationGuard.lowerBound, serviceConstruction.lowerBound)
        let runnerLaunch = try XCTUnwrap(app.range(
            of: "ProductionSyncQualificationRunner.runIfRequested()"))
        let ordinaryActivation = try XCTUnwrap(app.range(
            of: "launch.activateReadyServicesIfNeeded()"))
        XCTAssertLessThan(runnerLaunch.lowerBound, ordinaryActivation.lowerBound)
        XCTAssertTrue(delegate.contains(
            "ProductionSyncQualificationPushBridge"))
        XCTAssertTrue(delegate.contains("handler()"))
        XCTAssertEqual(
            delegate.components(separatedBy:
                "guard !runsProductionSyncQualification else { return }").count - 1,
            2)
        let launchIsolation = try XCTUnwrap(delegate.range(
            of: "guard !runsProductionSyncQualification else { return }"))
        let notificationMutation = try XCTUnwrap(delegate.range(
            of: "UNUserNotificationCenter.current()"))
        XCTAssertLessThan(
            launchIsolation.lowerBound,
            notificationMutation.lowerBound)
    }

    func testProductionSyncQualificationOwnerIsFailClosed() throws {
        let owner = try Self.contents(
            of: "scripts/production_sync_qualification.py")
        let packager = try Self.contents(
            of: "scripts/make-production-sync-qualification-app.sh")
        let hygiene = try Self.contents(
            of: "scripts/check-repository-hygiene.sh")
        let makefile = try Self.contents(of: "Makefile")

        XCTAssertTrue(owner.contains("def validate_stage_prerequisites("))
        XCTAssertTrue(owner.contains("def validate_live_stage_relationship("))
        XCTAssertTrue(owner.contains("canonical_document_sha256(authority)"))
        XCTAssertTrue(owner.contains("codeResourcesSHA256"))
        XCTAssertTrue(owner.contains("provisioningProfileSHA256"))
        XCTAssertTrue(owner.contains("def require_stage_workspace_location("))
        XCTAssertTrue(owner.contains("def prepare_stage_directories("))
        XCTAssertTrue(owner.contains("--untracked-files=all"))
        XCTAssertTrue(owner.contains("if not key.startswith(\"PORTAVOZ_\")"))
        XCTAssertTrue(owner.contains("each stage must run in a distinct app process"))
        XCTAssertTrue(owner.contains("two distinct Mac host scopes"))
        XCTAssertTrue(owner.contains("another account"))
        XCTAssertTrue(owner.contains("os.replace(staging, output)"))
        XCTAssertEqual(
            owner.components(separatedBy: "\ndef qualification_receipt(").count - 1,
            1)
        XCTAssertEqual(
            owner.components(separatedBy: "receipt = qualification_receipt(").count - 1,
            1)
        XCTAssertFalse(owner.contains("/Applications/"))
        XCTAssertFalse(owner.contains("proof-state"))

        XCTAssertTrue(packager.contains(
            "production-sync-qualification.json"))
        XCTAssertTrue(packager.contains("--untracked-files=all"))
        XCTAssertTrue(hygiene.contains(
            "Tests.Tooling.test_production_sync_qualification"))
        for target in [
            "production-sync-qualification-init:",
            "production-sync-qualification-stage:",
            "production-sync-qualification-status:",
            "production-sync-qualification-finalize:"
        ] {
            XCTAssertTrue(makefile.contains(target))
        }
        XCTAssertTrue(makefile.contains(
            "PORTAVOZ_PRODUCTION_SYNC_APP ?= $(CURDIR)/dist/Portavoz Sync Qualification.app"))
        XCTAssertFalse(makefile.contains(
            "$(abspath dist/Portavoz Sync Qualification.app)"))
    }

    func testProductionSyncQualificationTruthIsDocumented() throws {
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")
        let quality = try Self.contents(of: "docs/specs/08-quality.md")
        let releasing = try Self.contents(of: "docs/RELEASING.md")
        let gaps = try Self.contents(of: "docs/GAPS.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(architecture.contains(
            "Staged production-sync qualification"))
        XCTAssertTrue(appSpec.contains(
            "real-app production-sync qualification"))
        XCTAssertTrue(quality.contains(
            "ProductionSyncQualificationTests"))
        XCTAssertTrue(releasing.contains(
            "production-sync-qualification-init"))
        XCTAssertTrue(gaps.contains(
            "STAGED PRODUCER IMPLEMENTED (D404)"))
        XCTAssertTrue(decisions.contains("## D404"))
    }

    func testAssistiveTechnologyQualificationOwnerIsFailClosed() throws {
        let contract = try Self.jsonObject(
            at: "docs/evidence/assistive-technology-qualification.json")
        let technologies = try XCTUnwrap(
            contract["technologies"] as? [[String: Any]])
        let checkpoints = try XCTUnwrap(
            contract["checkpoints"] as? [[String: Any]])
        let owner = try Self.contents(
            of: "scripts/assistive_technology_qualification.py")
        let evaluator = try Self.contents(
            of: "scripts/release_reliability.py")
        let hygiene = try Self.contents(
            of: "scripts/check-repository-hygiene.sh")
        let makefile = try Self.contents(of: "Makefile")

        XCTAssertEqual(contract["schemaVersion"] as? Int, 1)
        XCTAssertEqual(
            contract["kind"] as? String,
            "assistive-technology-qualification-contract")
        XCTAssertEqual(
            technologies.compactMap { $0["id"] as? String },
            ["voiceover", "voice-control"])
        XCTAssertEqual(checkpoints.count, 6)
        XCTAssertEqual(
            checkpoints.compactMap { $0["sequence"] as? Int },
            Array(1...6))

        XCTAssertTrue(owner.contains("EXPECTED_PLATFORMS"))
        XCTAssertTrue(owner.contains("EXPECTED_TECHNOLOGIES"))
        XCTAssertTrue(owner.contains("EXPECTED_CHECKPOINTS"))
        XCTAssertTrue(owner.contains("--untracked-files=all"))
        XCTAssertTrue(owner.contains("candidateReceiptSHA256"))
        XCTAssertTrue(owner.contains("CodeResources"))
        XCTAssertTrue(owner.contains("Developer ID Application:"))
        XCTAssertTrue(owner.contains("NSWorkspace.sharedWorkspace.isVoiceOverEnabled"))
        XCTAssertTrue(owner.contains(#""authority": "human-observed""#))
        XCTAssertTrue(owner.contains(
            #"exclusive_reservation(evidence_root, "start-locale")"#))
        XCTAssertTrue(owner.contains("os.link(temporary_path, path"))
        XCTAssertTrue(owner.contains("terminate_owned_process("))
        XCTAssertTrue(owner.contains(
            "failed candidate launch did not exit after graceful cleanup"))
        XCTAssertTrue(owner.contains(
            "a failed observation makes the cell immutable"))
        XCTAssertTrue(owner.contains(
            "Sequoia and Tahoe must use distinct Mac host scopes"))
        XCTAssertTrue(owner.contains(
            "cryptographically attest physical hardware."))
        XCTAssertTrue(owner.contains("canonical_document_sha256(authority)"))
        XCTAssertFalse(owner.contains("os.chmod(output.parent"))
        XCTAssertFalse(owner.contains("proof-state"))

        XCTAssertTrue(evaluator.contains(
            #""authorityKind": "assistive-technology-authority""#))
        XCTAssertTrue(hygiene.contains(
            "Tests.Tooling.test_assistive_technology_qualification"))
        for target in [
            "test-assistive-technology-qualification:",
            "assistive-qualification-init:",
            "assistive-qualification-start:",
            "assistive-qualification-observe:",
            "assistive-qualification-finish:",
            "assistive-qualification-status:",
            "assistive-qualification-finalize:"
        ] {
            XCTAssertTrue(makefile.contains(target))
        }
        XCTAssertTrue(makefile.contains(
            "PORTAVOZ_ASSISTIVE_APP ?= /Applications/Portavoz Dev.app"))
        XCTAssertFalse(makefile.contains(
            "PORTAVOZ_ASSISTIVE_APP ?= /Applications/Portavoz.app"))
    }

    func testAssistiveTechnologyQualificationTruthIsDocumented() throws {
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let quality = try Self.contents(of: "docs/specs/08-quality.md")
        let releasing = try Self.contents(of: "docs/RELEASING.md")
        let runbook = try Self.contents(of: "docs/ASSISTIVE-VALIDATION.md")
        let gaps = try Self.contents(of: "docs/GAPS.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(architecture.contains(
            "Physical assistive-technology qualification"))
        XCTAssertTrue(quality.contains(
            "Physical assistive-technology owner (D405)"))
        XCTAssertTrue(releasing.contains(
            "physical assistive-technology qualification (D405)"))
        XCTAssertTrue(runbook.contains(
            "VoiceOver and Voice Control must run on the same host"))
        XCTAssertTrue(runbook.contains(
            "do **not** cryptographically attest physical hardware"))
        XCTAssertTrue(gaps.contains(
            "BOUNDED PRODUCER IMPLEMENTED (D405)"))
        XCTAssertTrue(decisions.contains("## D405"))
    }

    func testDevelopmentAndUITestAppsCannotClaimTheReleaseIdentity() throws {
        let makefile = try Self.contents(of: "Makefile")
        let project = try Self.contents(of: "project.yml")
        let collector = try Self.contents(of: "scripts/collect-field-evidence.py")

        XCTAssertTrue(makefile.contains("app.portavoz.mac.dev"))
        XCTAssertTrue(project.contains(
            "PRODUCT_BUNDLE_IDENTIFIER: app.portavoz.mac.uitest-host"))
        XCTAssertTrue(collector.contains(
            #"CFBundleIdentifier") != "app.portavoz.mac.dev""#))
        XCTAssertFalse(project.contains(
            "PRODUCT_BUNDLE_IDENTIFIER: app.portavoz.mac\n"))
    }

    func testDisposableUITestWindowsStayOnAppKitsZeroScreen() throws {
        let placement = try Self.contents(
            of: "Sources/portavoz-app/UITestWindowPlacement.swift")
        let content = try Self.contents(of: "Sources/portavoz-app/ContentView.swift")
        let settingsCapture = try Self.contents(
            of: "Sources/portavoz-app/SettingsSkillReceiptNavigation.swift")
        let uiTestSupport = try Self.contents(
            of: "Tests/PortavozUITests/UITestSupport.swift")

        XCTAssertTrue(placement.contains(
            #"arguments.contains("-use-temp-store")"#))
        XCTAssertTrue(placement.contains(
            #"PORTAVOZ_UI_TEST_ALLOW_NOTIFICATION_CENTER_ALERTS"#))
        XCTAssertTrue(placement.contains(
            #"window.level = .statusBar"#))
        XCTAssertTrue(placement.contains("NSScreen.screens.first"))
        XCTAssertFalse(placement.contains("NSScreen.main"))
        XCTAssertFalse(placement.contains("window.screen"))
        XCTAssertTrue(placement.contains("window.constrainFrameRect(frame, to: screen)"))
        XCTAssertTrue(content.contains("UITestMainWindowCapture()"))
        XCTAssertFalse(content.contains("NSApp.windows.first"))
        XCTAssertTrue(placement.contains("override func viewDidMoveToWindow()"))
        XCTAssertTrue(placement.contains("private weak var positionedWindow: NSWindow?"))
        XCTAssertTrue(placement.contains("if let window { position(window) }"))
        for file in ["CommandPalette.swift", "RecordingHUD.swift",
                     "DictationPanel.swift", "MeetingReminder.swift"] {
            let panel = try Self.contents(of: "Sources/portavoz-app/\(file)")
            XCTAssertTrue(panel.contains(
                "panel.level = UITestWindowPlacement.floatingPanelLevel()"), file)
        }
        XCTAssertTrue(settingsCapture.contains(
            "UITestWindowPlacement.positionSettingsWindow(window)"))
        XCTAssertTrue(uiTestSupport.contains(
            #"general.frame.minX,"#))
        XCTAssertTrue(uiTestSupport.contains(
            #"temporary Settings must stay on AppKit's zero screen"#))
        XCTAssertTrue(uiTestSupport.contains(
            #"app.launchEnvironment[notificationCenterAlertOverride] = "true""#))
        XCTAssertFalse(uiTestSupport.contains("addUIInterruptionMonitor"))
    }

    func testProductionSandboxDecisionStaysExplicitAndReproducible() throws {
        let productionEntitlements = try Self.contents(of: "packaging/portavoz.entitlements")
        let probeEntitlements = try Self.contents(
            of: "scripts/sandbox-spike/probe.entitlements")
        let runner = try Self.contents(of: "scripts/run-sandbox-capability-spike.sh")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let evidence = try Self.contents(
            of: "docs/evidence/app-sandbox-capability-spike-20260716.json")

        XCTAssertFalse(productionEntitlements.contains("com.apple.security.app-sandbox"))
        XCTAssertTrue(probeEntitlements.contains("com.apple.security.app-sandbox"))
        XCTAssertTrue(runner.contains("SandboxCapabilityProbe.swift"))
        XCTAssertTrue(runner.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(runner.contains("sandboxEnforcementObserved"))
        XCTAssertTrue(evidence.contains(#""signingMode": "developer-id""#))
        XCTAssertTrue(evidence.contains(#""sandboxed""#))
        XCTAssertTrue(evidence.contains(#""nonSandboxedControl""#))
        XCTAssertEqual(
            evidence.components(separatedBy: "graph-started-and-stopped").count - 1,
            4,
            "Sandbox and control must each prove microphone and process-tap graph setup")
        XCTAssertTrue(decisions.contains("## D78"))
    }
}
