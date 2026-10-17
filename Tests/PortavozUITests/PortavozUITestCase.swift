import Darwin
import XCTest

/// Owns each journey's scratch and prevents XCTest's fallback monitors from
/// making a permission decision when an unexpected window blocks an action.
@MainActor
class PortavozUITestCase: XCTestCase {
    private let storageOwnerID = UUID()
    private var runnerActivity: (any NSObjectProtocol)?

    var hasActiveUITestRunnerActivity: Bool { runnerActivity != nil }

    override func setUp() async throws {
        try await super.setUp()
        try UITestStorage.begin(ownerID: storageOwnerID)
        // Classify only this runner's owned work; this neither grants input
        // authority nor prevents the user's Mac from sleeping on idle.
        runnerActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Running an owned Portavoz UI journey")
        addUIInterruptionMonitor(withDescription: "Stop without answering an unexpected interruption") { _ in
            self.stopForUnexpectedInterruption(reason: "interruption")
        }
    }

    override func tearDown() async throws {
        defer {
            if let runnerActivity {
                ProcessInfo.processInfo.endActivity(runnerActivity)
                self.runnerActivity = nil
            }
        }
        // A named child activity makes owned app exit and scratch removal
        // visible inside Tear Down. Runtime attribution then retains that work
        // instead of treating an apparently empty teardown as harness noise.
        let cleanup = XCTContext.runActivity(named: "Finish owned UI test cleanup") { _ in
            Result { try UITestStorage.end(ownerID: storageOwnerID, allowOwnedExit: hasHealthyTestRun) }
        }
        try await super.tearDown()
        _ = try cleanup.get()
    }

    private var hasHealthyTestRun: Bool {
        testRun.map { run in
            run.failureCount == 0 && run.unexpectedExceptionCount == 0
        } == true
    }

    /// Final disposal only. Recovery/crash exercises continue to call the
    /// official XCTest termination API at their original journey boundary.
    @discardableResult
    func finishUITestApplication(_ application: XCUIApplication) -> UITestStorage.FinishOutcome {
        let outcome = UITestStorage.finish(application, allowOwnedExit: hasHealthyTestRun)
        XCTAssertNotEqual(outcome, .identityLost, "Final cleanup lost its captured launch identity")
        return outcome
    }

    var keyboardReceiverBundleIdentifier: String { XCUIApplication.portavozUITestHostBundleIdentifier }

    func typeText(_ text: String, in app: XCUIApplication, modalAnchor: String? = nil) {
        let admission = app.typeTextIfOwned(
            text, bundleIdentifier: keyboardReceiverBundleIdentifier, modalAnchor: modalAnchor)
        guard admission == .admitted else {
            stopForUnexpectedInterruption(reason: admission.stopReason)
        }
    }

    @nonobjc
    func typeKey(
        _ key: XCUIKeyboardKey,
        modifierFlags: XCUIElement.KeyModifierFlags,
        in app: XCUIApplication,
        modalAnchor: String? = nil
    ) {
        let admission = app.typeKeyIfOwned(
            key, modifierFlags: modifierFlags,
            bundleIdentifier: keyboardReceiverBundleIdentifier, modalAnchor: modalAnchor)
        guard admission == .admitted else {
            stopForUnexpectedInterruption(reason: admission.stopReason)
        }
    }

    @nonobjc
    func typeKey(
        _ key: String,
        modifierFlags: XCUIElement.KeyModifierFlags,
        in app: XCUIApplication,
        modalAnchor: String? = nil
    ) {
        typeKey(XCUIKeyboardKey(rawValue: key), modifierFlags: modifierFlags, in: app, modalAnchor: modalAnchor)
    }

    private func stopForUnexpectedInterruption(reason: String) -> Never {
        // Own the cleanup before exiting; XCTest cannot safely resume this
        // callback or its fallback handlers after an unexpected interruption.
        let cleanup: String
        do {
            // `absent` means this owner had no live session to clean; it is
            // never reported as completed cleanup.
            cleanup = try UITestStorage.end(ownerID: storageOwnerID) ? "complete" : "absent"
        } catch {
            // Do not interpolate errors: they may contain a private file path.
            cleanup = "failed"
        }
        let message = "PORTAVOZ_UI_INTERRUPTION_BLOCKED cleanup=\(cleanup) reason=\(reason)"
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        // Recording an XCTest issue here can reenter async teardown on the main actor.
        exit(EXIT_FAILURE)
    }
}
