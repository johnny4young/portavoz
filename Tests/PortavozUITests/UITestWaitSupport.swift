import AppKit
import XCTest

/// Evaluate an explicit state predicate without XCTest's one-second polling
/// floor. The run loop stays live between probes, so asynchronous app and
/// accessibility updates continue to arrive; there is no blind fixed delay.
@MainActor
@discardableResult
func waitForUITestCondition(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.05,
    _ condition: () throws -> Bool
) rethrows -> Bool {
    if try condition() { return true }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let nextProbe = min(deadline, Date().addingTimeInterval(pollInterval))
        // `run(mode:before:)` may return after any handled source, which turns
        // a requested polling interval into an unbounded AX-query loop. Keep
        // servicing the default run loop until the actual probe boundary.
        RunLoop.current.run(until: nextProbe)
        if try condition() { return true }
    }
    return false
}

extension XCUIApplication {
    /// The only bundle the disposable Portavoz UI-test launch runs as. Shared
    /// helpers and the base case's default keyboard receiver use this value.
    nonisolated static let portavozUITestHostBundleIdentifier = "app.portavoz.mac.uitest-host"

    /// XCUITest can report `.notRunning` before LaunchServices removes the
    /// process from its inventory. Observe the real host state instead of
    /// sleeping on every launch; an already-clear host returns immediately.
    @MainActor
    func waitForPortavozProcessExit(timeout: TimeInterval = 10) -> Bool {
        waitForUITestCondition(timeout: timeout) {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.portavozUITestHostBundleIdentifier
            ).isEmpty
        }
    }
}
