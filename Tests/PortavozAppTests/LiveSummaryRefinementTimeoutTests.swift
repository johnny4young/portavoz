import XCTest
@testable import portavoz_app

final class LiveSummaryRefinementTimeoutTests: XCTestCase {
    func testReturnsProviderValueBeforeDeadline() async throws {
        let value = try await withLiveSummaryRefinementTimeout(.seconds(1)) {
            "refined"
        }

        XCTAssertEqual(value, "refined")
    }

    func testTimeoutCancelsCooperativeProviderWithoutWaitingForItsDelay() async {
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try await withLiveSummaryRefinementTimeout(.milliseconds(10)) {
                try await Task.sleep(for: .seconds(5))
                return "late"
            }
            XCTFail("the timeout must win")
        } catch is LiveSummaryRefinementTimeoutError {
            let elapsed = started.duration(to: clock.now)
            XCTAssertLessThan(elapsed, .milliseconds(500))
        } catch {
            XCTFail("unexpected timeout result: \(error)")
        }
    }

    func testParentCancellationRemainsCancellation() async {
        let task = Task {
            try await withLiveSummaryRefinementTimeout(.seconds(5)) {
                try await Task.sleep(for: .seconds(5))
                return "late"
            }
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled refinement must not publish")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("parent cancellation changed type: \(error)")
        }
    }
}
