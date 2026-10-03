import Foundation
import Testing

@testable import portavoz_app

extension DictationTextModeDeliveryTests {
    nonisolated static let nativeAdmissionFlags = [true, false].flatMap { temporary in
        [true, false].flatMap { seeded in
            [true, false].map { (temporary, seeded, $0) }
        }
    }

    @Test(arguments: nativeAdmissionFlags)
    func nativeControllerFixtureRequiresScriptedRecognitionAndTemporaryComposition(
        _ flags: (Bool, Bool, Bool)
    ) {
        let (temporary, seeded, english) = flags
        var arguments = ["-seed-dictation-native", "-seed-dictation-native-controller"]
        if seeded { arguments.append("-seed-dictation") }
        if english { arguments.append("-seed-dictation-english") }
        let fixture = DictationNativeUITestFixture(
            arguments: arguments,
            environment: [DictationNativeUITestFixture.environmentKey:
                DictationNativeUITestFixture.pasteboardPrefix + UUID().uuidString,
                DictationNativeUITestFixture.controlEnvironmentKey:
                DictationNativeUITestFixture.pasteboardPrefix + UUID().uuidString],
            usesTemporaryStore: temporary)
        #expect((fixture != nil) == (temporary && seeded && english))
        if let fixture {
            #expect(fixture.status == "idle")
            fixture.start()
            #expect(fixture.status == "controller-required", "Never fall back to direct paste without a controller")
        }
    }

    @Test(arguments: [nil, "", "NSGeneralPboard", "app.portavoz.dictation-test.invalid"] as [String?])
    func nativeControllerRejectsUnavailableControlBoards(_ controlName: String?) {
        let name = DictationNativeUITestFixture.pasteboardPrefix + UUID().uuidString
        var environment = [DictationNativeUITestFixture.environmentKey: name]
        environment[DictationNativeUITestFixture.controlEnvironmentKey] = controlName
        let flags = ["-seed-dictation-native", "-seed-dictation-native-controller",
                     "-seed-dictation", "-seed-dictation-english"]
        #expect(DictationNativeUITestFixture(
            arguments: flags, environment: environment, usesTemporaryStore: true) == nil)
        environment[DictationNativeUITestFixture.controlEnvironmentKey] = name
        #expect(DictationNativeUITestFixture(
            arguments: flags, environment: environment, usesTemporaryStore: true) == nil,
                "The command board must never mutate the clipboard being measured")
    }

    @Test
    func nativePostingDenialCannotArmEitherInsertionPath() throws {
        for runsController in [false, true] {
            let harness = DictationControllerHarness(text: "Don't delete these notes.")
            var flags = ["-seed-dictation-native"]
            if runsController {
                flags += ["-seed-dictation-native-controller", "-seed-dictation", "-seed-dictation-english"]
            }
            let fixture = try #require(DictationNativeUITestFixture(
                arguments: flags,
                environment: [DictationNativeUITestFixture.environmentKey:
                    DictationNativeUITestFixture.pasteboardPrefix + UUID().uuidString,
                    DictationNativeUITestFixture.controlEnvironmentKey:
                    DictationNativeUITestFixture.pasteboardPrefix + UUID().uuidString],
                usesTemporaryStore: true))
            var preflightCalls = 0
            for _ in 0..<2 {
                fixture.start(controller: harness.controller, dependencies: harness.dependencies, postingPreflight: {
                    preflightCalls += 1
                    return false
                })
                #expect(fixture.status == "event-posting-required-for-app")
                #expect(harness.controller.phase == .idle)
                #expect(harness.insertions.isEmpty)
                #expect(harness.hints == nil)
                #expect(harness.finishes == 0)
            }
            #expect(preflightCalls == 2, "A denial must not retain a task that conceals subsequent preflight")
        }
    }

    @Test
    func nativeJourneyDriverReachesTheRealControllerAndWaitsForTheChoice() async throws {
        let harness = DictationControllerHarness(text: "Don't delete these notes.")
        harness.set("literal", forKey: DictationTextPreferences.modeKey)
        harness.set(#"[{"trigger":"notes","replacement":"documents"}]"#,
                    forKey: DictationController.replacementsKey)
        var stopRequested = false
        var stopPolls = 0
        let task = Task { await DictationNativeControllerUITestFixture.run(
            controller: harness.controller, dependencies: harness.dependencies, stopRequested: {
                stopPolls += 1
                return stopRequested
            }) }
        defer { task.cancel(); harness.controller.cancel() }
        try await waitForNativeDriver { harness.controller.partialText == harness.text }
        #expect(harness.controller.textMode == .literal)
        #expect(harness.insertions.isEmpty)
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.selectTextMode(.clean)
        try await waitForNativeDriver { stopPolls > 0 }
        #expect(harness.insertions.isEmpty, "Mode selection alone is not the Stop gesture")
        #expect(harness.controller.isActive)
        stopRequested = true
        #expect(await task.value == "inserted")
        #expect(harness.insertions == ["Don't delete these documents."])
        #expect(harness.controller.phase == .idle)
        try await waitForNativeDriver { harness.finishes == 1 }
    }

    @Test
    func cancellingTheNativeDriverDoesNotInsertOrLeaveCaptureActive() async throws {
        let harness = DictationControllerHarness(text: "Don't delete these notes.")
        harness.set("literal", forKey: DictationTextPreferences.modeKey)
        let task = Task { await DictationNativeControllerUITestFixture.run(
            controller: harness.controller, dependencies: harness.dependencies, stopRequested: { false }) }
        defer { task.cancel(); harness.controller.cancel() }
        try await waitForNativeDriver { harness.controller.partialText == harness.text }
        task.cancel()
        #expect(await task.value == "controller-cancelled")
        #expect(harness.controller.phase == .idle)
        #expect(harness.insertions.isEmpty)
        try await waitForNativeDriver { harness.finishes == 1 }
    }

    @Test
    func cancelledDriverNeverStartsAControllerSession() async {
        let harness = DictationControllerHarness(text: "Don't delete these notes.")
        let task = Task { await DictationNativeControllerUITestFixture.run(
            controller: harness.controller, dependencies: harness.dependencies, stopRequested: { false }) }
        task.cancel()
        #expect(await task.value == "controller-cancelled")
        #expect(harness.controller.phase == .idle)
        #expect(harness.insertions.isEmpty)
        #expect(harness.hints == nil)
        #expect(harness.finishes == 0)
    }

    @Test
    func nativeDriverCannotReplaceOrCancelAnAlreadyActiveSession() async throws {
        let harness = DictationControllerHarness(text: "Don't delete these notes.")
        harness.controller.toggle(using: harness.dependencies)
        defer { harness.controller.cancel() }
        try await waitForNativeDriver { harness.controller.partialText == harness.text }
        #expect(await DictationNativeControllerUITestFixture.run(
            controller: harness.controller, dependencies: harness.dependencies,
            stopRequested: { true }) == "controller-busy")
        #expect(harness.controller.isActive)
        #expect(harness.insertions.isEmpty)
        #expect(harness.finishes == 0)
    }

    private func waitForNativeDriver(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}
