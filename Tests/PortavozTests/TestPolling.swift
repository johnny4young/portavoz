import Foundation

/// Polls for a state the code under test must reach. Only
/// `ControlledTestSleep.hangGuard` bounds it, so a loaded runner running
/// suites in parallel cannot fail a correct test.
enum TestPolling {
    private static let interval: Duration = .milliseconds(5)

    @MainActor
    static func until(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: ControlledTestSleep.hangGuard)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: interval)
        }
        return condition()
    }

    static func untilAsync(
        isolation: isolated (any Actor)? = #isolation,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: ControlledTestSleep.hangGuard)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: interval)
        }
        return await condition()
    }
}
