import XCTest

extension ArchitectureDependencyTests {
    func testUITestRunnerClassificationIsBoundedAndNeverGrantsInputAuthority() throws {
        let source = try Self.contents(of: "Tests/PortavozUITests/PortavozUITestCase.swift")
        let admission = try XCTUnwrap(source.range(of: "try UITestStorage.begin(ownerID: storageOwnerID)"))
        let begin = try XCTUnwrap(source.range(of: "runnerActivity = ProcessInfo.processInfo.beginActivity("))
        let monitor = try XCTUnwrap(source.range(of: "addUIInterruptionMonitor("))
        XCTAssertLessThan(admission.lowerBound, begin.lowerBound)
        XCTAssertLessThan(begin.lowerBound, monitor.lowerBound)
        XCTAssertEqual(source.components(separatedBy: "beginActivity(").count - 1, 1)
        XCTAssertTrue(source.contains("options: .userInitiatedAllowingIdleSystemSleep"))
        for forbidden in [".latencyCritical", ".userInteractive", ".idleSystemSleepDisabled",
                          ".idleDisplaySleepDisabled", "PORTAVOZ_UI_RUNNER_ACTIVITY_MODE"] {
            XCTAssertFalse(source.contains(forbidden))
        }
        let start = try XCTUnwrap(source.range(of: "override func tearDown() async throws {"))
        let end = try XCTUnwrap(source.range(of: "private var hasHealthyTestRun"))
        let teardown = String(source[start.lowerBound..<end.lowerBound])
        let deferred = try XCTUnwrap(teardown.range(of: "defer {"))
        let release = try XCTUnwrap(teardown.range(of: "ProcessInfo.processInfo.endActivity(runnerActivity)"))
        let clear = try XCTUnwrap(teardown.range(of: "self.runnerActivity = nil"))
        let cleanup = try XCTUnwrap(teardown.range(of: "let cleanup = XCTContext.runActivity("))
        XCTAssertLessThan(deferred.lowerBound, release.lowerBound)
        XCTAssertLessThan(release.lowerBound, clear.lowerBound)
        XCTAssertLessThan(clear.lowerBound, cleanup.lowerBound,
                          "the release belongs to the function-wide defer, including thrown cleanup")
        XCTAssertTrue(teardown.contains("try await super.tearDown()"))
        XCTAssertTrue(teardown.contains("_ = try cleanup.get()"))
        for path in ["Tests/PortavozUITests/UITestKeyboardSupport.swift",
                     "Tests/PortavozUITests/UITestSupport.swift"] {
            XCTAssertFalse(try Self.contents(of: path).contains("hasActiveUITestRunnerActivity"))
        }
    }
}
